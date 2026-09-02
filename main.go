package main

import (
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/signal"
	"syscall"
	"time"

	"google.golang.org/grpc"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	logsapi "k8s.io/component-base/logs/api/v1"
	logsjson "k8s.io/component-base/logs/json"
	"k8s.io/klog/v2"
	csidriver "sigs.k8s.io/secrets-store-csi-driver/provider/v1alpha1"

	"github.com/aws/secrets-store-csi-driver-provider-aws/provider"
	"github.com/aws/secrets-store-csi-driver-provider-aws/server"
)

var (
	endpointDir            = flag.String("provider-volume", "/var/run/secrets-store-csi-providers", "Rendezvous directory for provider socket")
	driverWriteSecrets     = flag.Bool("driver-writes-secrets", false, "The driver will do the write instead of the plugin")
	qps                    = flag.Int("qps", 5, "Maximum query per second to the Kubernetes API server. To mount the requested secret on the pod, the AWS CSI provider lookups the region of the pod and the role ARN associated with the service account by calling the K8s APIs. Increase the value if the provider is throttled by client-side limit to the API server.")
	burst                  = flag.Int("burst", 10, "Maximum burst for throttle. To mount the requested secret on the pod, the AWS CSI provider lookups the region of the pod and the role ARN associated with the service account by calling the K8s APIs. Increase the value if the provider is throttled by client-side limit to the API server.")
	eksAddonVersion        = flag.String("eks-addon-version", "", "The EKS addon version of the provider")
	podIdentityHttpTimeout = flag.String("pod-identity-http-timeout", "", "The HTTP timeout threshold for Pod Identity authentication.")
	logFormatJSON          = flag.Bool("log-format-json", false, "Set log formatter to JSON")
)

// parsePodIdentityHttpTimeout parses and validates the HTTP timeout for Pod Identity authentication
func parsePodIdentityHttpTimeout(timeoutStr string) *time.Duration {
	if timeoutStr == "" {
		return nil
	}

	duration, err := time.ParseDuration(timeoutStr)
	if err != nil {
		klog.Errorf("failed to parse podIdentityHttpTimeout value '%s': %v, using default SDK value", timeoutStr, err)
		return nil
	}

	if duration <= 0 {
		klog.Errorf("podIdentityHttpTimeout must be positive, got: %v, using default SDK value", duration)
		return nil
	}

	if duration > 30*time.Second {
		klog.Warningf("podIdentityHttpTimeout value %v is unusually high, consider using a smaller value", duration)
	}

	return &duration
}

// createSocket creates a Unix domain socket at the given path with restricted
// permissions (0700) so that only the owner (root) can connect.
func createSocket(endpoint string) (net.Listener, error) {
	oldMask := syscall.Umask(0077)
	listener, err := net.Listen("unix", endpoint)
	syscall.Umask(oldMask)
	if err != nil {
		return nil, fmt.Errorf("failed to listen on %s: %w", endpoint, err)
	}
	if err := os.Chmod(endpoint, 0700); err != nil {
		listener.Close()
		return nil, fmt.Errorf("failed to set socket permissions: %w", err)
	}
	return listener, nil
}

// configureLogging replaces the default klog text output with a logger that
// emits log entries in JSON format to the given stream when jsonFormat is set.
//
// jsonFormat is passed in rather than read from the flag directly so that this
// stays a pure function of its arguments; reading *logFormatJSON here would
// silently do nothing if it ever ran before flag.Parse().
func configureLogging(jsonFormat bool, out io.Writer) {
	if !jsonFormat {
		return
	}
	// Only ErrorStream is consulted while SplitStream is false (the default),
	// but InfoStream is set to the same writer so that enabling SplitStream
	// later cannot leave the factory with a nil writer.
	logger, control := logsjson.Factory{}.Create(
		*logsapi.NewLoggingConfiguration(),
		logsapi.LoggingOptions{ErrorStream: out, InfoStream: out},
	)
	// ContextualLogger(true) makes klog.Background()/FromContext() return this
	// logger directly, matching how component-base installs the factory itself.
	// Without it, client-go's contextual log calls are serialized to text by
	// klog first and arrive here as one flattened msg string.
	klog.SetLoggerWithOptions(logger, klog.ContextualLogger(true), klog.FlushLogger(control.Flush))
}

// logFatal logs err at error severity and terminates the process. It replaces
// klog.Fatalf, whose logr bridge demotes fatal messages to info severity when
// a structured logger is installed via configureLogging.
func logFatal(err error, msg string) {
	klog.ErrorS(err, msg)
	klog.FlushAndExit(klog.ExitFlushTimeout, 1)
}

// Main entry point for the Secret Store CSI driver AWS provider. This main
// rountine starts up the gRPC server that will listen for incoming mount
// requests.
func main() {

	flag.Parse() // Parse command line flags

	configureLogging(*logFormatJSON, os.Stderr)
	defer klog.Flush()

	klog.Infof("Starting %s version %s", server.ProviderName, server.Version)
	klog.Infof("This provider requires tokenRequests to be configured in the CSIDriver spec (audiences: sts.amazonaws.com, pods.eks.amazonaws.com)")

	//socket on which to listen to for driver calls
	endpoint := fmt.Sprintf("%s/aws.sock", *endpointDir)
	os.Remove(endpoint) // Make sure to start clean.
	grpcSrv := grpc.NewServer()

	//Gracefully terminate server on shutdown unix signals
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGTERM, syscall.SIGINT)

	go func() {
		sig := <-sigs
		klog.Infof("received signal:%s to terminate", sig)
		grpcSrv.GracefulStop()
	}()

	listener, err := createSocket(endpoint)
	if err != nil {
		logFatal(err, "Failed to listen on unix socket")
	}

	cfg, err := rest.InClusterConfig()
	if err != nil {
		logFatal(err, "Can not get cluster config")
	}

	cfg.QPS = float32(*qps)
	cfg.Burst = *burst

	clientset, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		logFatal(err, "Can not initialize kubernetes client")
	}

	defer func() { // Cleanup on shutdown
		listener.Close()
		os.Remove(endpoint)
	}()

	// Parse and validate HTTP timeout
	podIdentityHttpTimeoutDuration := parsePodIdentityHttpTimeout(*podIdentityHttpTimeout)

	providerSrv, err := server.NewServer(provider.NewSecretProviderFactory, clientset.CoreV1(), *driverWriteSecrets, podIdentityHttpTimeoutDuration, *eksAddonVersion)
	if err != nil {
		logFatal(err, "Could not create server")
	}
	csidriver.RegisterCSIDriverProviderServer(grpcSrv, providerSrv)

	klog.Infof("Listening for connections on address: %s", listener.Addr())

	err = grpcSrv.Serve(listener)
	if err != nil {
		logFatal(err, "Failure serving incoming mount requests")
	}

}
