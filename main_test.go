package main

import (
	"flag"
	"os"
	"testing"
	"time"
)

func TestParsePodIdentityHttpTimeout(t *testing.T) {
	oneHundredMs := 100 * time.Millisecond
	twoSecs := 2 * time.Second
	fiveHundredMs := 500 * time.Millisecond
	thirtyFiveSecs := 35 * time.Second
	thirtySecs := 30 * time.Second
	thirtyPoint001Milliseconds := 30001 * time.Millisecond

	tests := []struct {
		name           string
		timeoutValue   string
		expectedResult *time.Duration
	}{
		{
			name:           "valid timeout - 100ms",
			timeoutValue:   "100ms",
			expectedResult: &oneHundredMs,
		},
		{
			name:           "valid timeout - 2s",
			timeoutValue:   "2s",
			expectedResult: &twoSecs,
		},
		{
			name:           "valid timeout - 500ms",
			timeoutValue:   "500ms",
			expectedResult: &fiveHundredMs,
		},
		{
			name:           "high timeout - 35s (should warn but return value)",
			timeoutValue:   "35s",
			expectedResult: &thirtyFiveSecs,
		},
		{
			name:           "invalid timeout format (should return default)",
			timeoutValue:   "invalid",
			expectedResult: nil,
		},
		{
			name:           "zero timeout (should return nil)",
			timeoutValue:   "0s",
			expectedResult: nil,
		},
		{
			name:           "negative timeout (should return nil)",
			timeoutValue:   "-100ms",
			expectedResult: nil,
		},
		{
			name:           "empty timeout (should use nil)",
			timeoutValue:   "",
			expectedResult: nil,
		},
		{
			name:           "exactly 30s (should not warn)",
			timeoutValue:   "30s",
			expectedResult: &thirtySecs,
		},
		{
			name:           "just over 30s (should warn but return value)",
			timeoutValue:   "30001ms",
			expectedResult: &thirtyPoint001Milliseconds,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := parsePodIdentityHttpTimeout(tt.timeoutValue)

			if result == nil && tt.expectedResult == nil {
				return
			}

			if result == nil || tt.expectedResult == nil {
				t.Errorf("Expected timeout %v, got %v", tt.expectedResult, result)
			}

			if *result != *tt.expectedResult {
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
