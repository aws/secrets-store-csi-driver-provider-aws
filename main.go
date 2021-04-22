package main

import (
	"net"
	"os"
	"os/signal"
	"syscall"

	"google.golang.org/grpc"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/klog/v2"
	csidriver "sigs.k8s.io/secrets-store-csi-driver/provider/v1alpha1"

	"github.com/aws/secrets-store-csi-driver-provider-aws/auth"
	"github.com/aws/secrets-store-csi-driver-provider-aws/provider"
	"github.com/aws/secrets-store-csi-driver-provider-aws/server"
)

// Main entry point for the Secret Store CSI driver AWS provider. This main
// rountine starts up the gRPC server that will listen for incoming mount
// requests.
func main() {

	klog.Infof("Starting %s version %s", auth.ProviderName, server.Version)

	//socket on which to listen to for driver calls
	endpoint := "/etc/kubernetes/secrets-store-csi-providers/aws.sock"
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

	clientset, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		klog.Fatalf("Can not initialize kubernetes client. error: %v", err)
	}

	defer listener.Close()
	providerSrv, err := server.NewServer(provider.NewSecretProviderFactory, clientset.CoreV1())
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
