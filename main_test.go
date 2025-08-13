package main

import (
	"flag"
	"os"
	"testing"
	"time"
)

func TestParsePodIdentityHttpTimeout(t *testing.T) {
	tests := []struct {
		name           string
		timeoutValue   string
		expectedResult time.Duration
	}{
		{
			name:           "valid timeout - 100ms",
			timeoutValue:   "100ms",
			expectedResult: 100 * time.Millisecond,
		},
		{
			name:           "valid timeout - 2s",
			timeoutValue:   "2s",
			expectedResult: 2 * time.Second,
		},
		{
			name:           "valid timeout - 500ms",
			timeoutValue:   "500ms",
			expectedResult: 500 * time.Millisecond,
		},
		{
			name:           "high timeout - 35s (should warn but return value)",
			timeoutValue:   "35s",
			expectedResult: 35 * time.Second,
		},
		{
			name:           "invalid timeout format (should return default)",
			timeoutValue:   "invalid",
			expectedResult: 100 * time.Millisecond,
		},
		{
			name:           "zero timeout (should return default)",
			timeoutValue:   "0s",
			expectedResult: 100 * time.Millisecond,
		},
		{
			name:           "negative timeout (should return default)",
			timeoutValue:   "-100ms",
			expectedResult: 100 * time.Millisecond,
		},
		{
			name:           "empty timeout (should use default)",
			timeoutValue:   "",
			expectedResult: 100 * time.Millisecond,
		},
		{
			name:           "exactly 30s (should not warn)",
			timeoutValue:   "30s",
			expectedResult: 30 * time.Second,
		},
		{
			name:           "just over 30s (should warn but return value)",
			timeoutValue:   "30001ms",
			expectedResult: 30001 * time.Millisecond,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := parsePodIdentityHttpTimeout(tt.timeoutValue)
			if result != tt.expectedResult {
				t.Errorf("Expected timeout %v, got %v", tt.expectedResult, result)
			}
		})
	}
}

// Test the flag parsing behavior
func TestFlagParsing(t *testing.T) {
	// Save original args
	oldArgs := os.Args
	defer func() { os.Args = oldArgs }()

	tests := []struct {
		name         string
		args         []string
		expectedFlag string
	}{
		{
			name:         "default timeout",
			args:         []string{"cmd"},
			expectedFlag: "100ms",
		},
		{
			name:         "custom timeout",
			args:         []string{"cmd", "--pod-identity-http-timeout=250ms"},
			expectedFlag: "250ms",
		},
		{
			name:         "custom timeout with equals",
			args:         []string{"cmd", "--pod-identity-http-timeout=2s"},
			expectedFlag: "2s",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Reset flags for each test
			flag.CommandLine = flag.NewFlagSet(os.Args[0], flag.ExitOnError)

			// Re-declare the flag (simulating what's in main.go)
			testPodIdentityHttpTimeout := flag.String("pod-identity-http-timeout", "100ms", "The HTTP timeout threshold for Pod Identity authentication.")

			// Set test args
			os.Args = tt.args

			// Parse flags
			flag.Parse()

			if *testPodIdentityHttpTimeout != tt.expectedFlag {
				t.Errorf("Expected flag value %s, got %s", tt.expectedFlag, *testPodIdentityHttpTimeout)
			}
		})
	}
}
