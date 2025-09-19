package main

import (
	"flag"
	"fmt"
	"net"
	"os"
	"os/signal"
	"syscall"
	"time"

	"google.golang.org/grpc"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/klog/v2"
	csidriver "sigs.k8s.io/secrets-store-csi-driver/provider/v1alpha1"

	"github.com/aws/secrets-store-csi-driver-provider-aws/auth"
	"github.com/aws/secrets-store-csi-driver-provider-aws/provider"
	"github.com/aws/secrets-store-csi-driver-provider-aws/server"
)

var (
	endpointDir            = flag.String("provider-volume", "/var/run/secrets-store-csi-providers", "Rendezvous directory for provider socket")
	driverWriteSecrets     = flag.Bool("driver-writes-secrets", false, "The driver will do the write instead of the plugin")
	qps                    = flag.Int("qps", 5, "Maximum query per second to the Kubernetes API server. To mount the requested secret on the pod, the AWS CSI provider lookups the region of the pod and the role ARN associated with the service account by calling the K8s APIs. Increase the value if the provider is throttled by client-side limit to the API server.")
	burst                  = flag.Int("burst", 10, "Maximum burst for throttle. To mount the requested secret on the pod, the AWS CSI provider lookups the region of the pod and the role ARN associated with the service account by calling the K8s APIs. Increase the value if the provider is throttled by client-side limit to the API server.")
	podIdentityHttpTimeout = flag.String("pod-identity-http-timeout", "", "The HTTP timeout threshold for Pod Identity authentication.")
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

// Main entry point for the Secret Store CSI driver AWS provider. This main
// rountine starts up the gRPC server that will listen for incoming mount
// requests.
func main() {

	klog.Infof("Starting %s version %s", auth.ProviderName, server.Version)

	flag.Parse() // Parse command line flags

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

	listener, err := net.Listen("unix", endpoint)
	if err != nil {
		klog.Fatalf("Failed to listen on unix socket. error: %v", err)
	}

	cfg, err := rest.InClusterConfig()
	if err != nil {
		klog.Fatalf("Can not get cluster config. error: %v", err)
	}

	cfg.QPS = float32(*qps)
	cfg.Burst = *burst

	clientset, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		klog.Fatalf("Can not initialize kubernetes client. error: %v", err)
	}

	defer func() { // Cleanup on shutdown
		listener.Close()
		os.Remove(endpoint)
	}()

	// Parse and validate HTTP timeout
	podIdentityHttpTimeoutDuration := parsePodIdentityHttpTimeout(*podIdentityHttpTimeout)

	providerSrv, err := server.NewServer(provider.NewSecretProviderFactory, clientset.CoreV1(), *driverWriteSecrets, podIdentityHttpTimeoutDuration)
	if err != nil {
		klog.Fatalf("Could not create server. error: %v", err)
	}
	csidriver.RegisterCSIDriverProviderServer(grpcSrv, providerSrv)

	klog.Infof("Listening for connections on address: %s", listener.Addr())

	err = grpcSrv.Serve(listener)
	if err != nil {
		klog.Fatalf("Failure serving incoming mount requests. error: %v", err)
	}

}
