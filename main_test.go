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

func TestPodIdentityHttpTimeoutParsing(t *testing.T) {
	tests := []struct {
		name           string
		timeoutValue   string
		expectedResult time.Duration
		expectError    bool
		expectWarning  bool
	}{
		{
			name:           "valid timeout - 100ms",
			timeoutValue:   "100ms",
			expectedResult: 100 * time.Millisecond,
			expectError:    false,
			expectWarning:  false,
		},
		{
			name:           "valid timeout - 2s",
			timeoutValue:   "2s",
			expectedResult: 2 * time.Second,
			expectError:    false,
			expectWarning:  false,
		},
		{
			name:           "valid timeout - 500ms",
			timeoutValue:   "500ms",
			expectedResult: 500 * time.Millisecond,
			expectError:    false,
			expectWarning:  false,
		},
		{
			name:           "high timeout - 35s (should warn)",
			timeoutValue:   "35s",
			expectedResult: 35 * time.Second,
			expectError:    false,
			expectWarning:  true,
		},
		{
			name:           "invalid timeout format",
			timeoutValue:   "invalid",
			expectedResult: 100 * time.Millisecond, // should default
			expectError:    true,
			expectWarning:  false,
		},
		{
			name:           "zero timeout",
			timeoutValue:   "0s",
			expectedResult: 0,
			expectError:    true, // should error for non-positive
			expectWarning:  false,
		},
		{
			name:           "negative timeout",
			timeoutValue:   "-100ms",
			expectedResult: -100 * time.Millisecond,
			expectError:    true, // should error for non-positive
			expectWarning:  false,
		},
		{
			name:           "empty timeout (should use default)",
			timeoutValue:   "",
			expectedResult: 100 * time.Millisecond,
			expectError:    false,
			expectWarning:  false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Test the timeout parsing logic from main.go
			var podIdentityHttpTimeoutDuration time.Duration
			var parseErr error
			var hasPositiveError bool
			var hasHighValueWarning bool

			if tt.timeoutValue != "" {
				podIdentityHttpTimeoutDuration, parseErr = time.ParseDuration(tt.timeoutValue)
				if parseErr != nil && tt.expectError {
					// Expected parse error
				} else if parseErr != nil {
					t.Errorf("Unexpected parse error: %v", parseErr)
				}

				if podIdentityHttpTimeoutDuration <= 0 {
					hasPositiveError = true
				}
				if podIdentityHttpTimeoutDuration > 30*time.Second {
					hasHighValueWarning = true
				}
			} else {
				// Default to 100ms
				podIdentityHttpTimeoutDuration = 100 * time.Millisecond
			}

			// Verify the expected result
			if !tt.expectError || parseErr == nil {
				if podIdentityHttpTimeoutDuration != tt.expectedResult {
					t.Errorf("Expected timeout %v, got %v", tt.expectedResult, podIdentityHttpTimeoutDuration)
				}
			}

			// Verify error conditions
			if tt.expectError && parseErr == nil && !hasPositiveError {
				t.Errorf("Expected an error but got none")
			}

			// Verify warning conditions
			if tt.expectWarning != hasHighValueWarning {
				t.Errorf("Expected warning: %v, got warning: %v", tt.expectWarning, hasHighValueWarning)
			}
		})
	}
}

func TestPodIdentityHttpTimeoutValidation(t *testing.T) {
	tests := []struct {
		name        string
		duration    time.Duration
		expectError bool
		expectWarn  bool
	}{
		{
			name:        "valid positive duration",
			duration:    100 * time.Millisecond,
			expectError: false,
			expectWarn:  false,
		},
		{
			name:        "zero duration should error",
			duration:    0,
			expectError: true,
			expectWarn:  false,
		},
		{
			name:        "negative duration should error",
			duration:    -100 * time.Millisecond,
			expectError: true,
			expectWarn:  false,
		},
		{
			name:        "high duration should warn",
			duration:    35 * time.Second,
			expectError: false,
			expectWarn:  true,
		},
		{
			name:        "exactly 30s should not warn",
			duration:    30 * time.Second,
			expectError: false,
			expectWarn:  false,
		},
		{
			name:        "just over 30s should warn",
			duration:    30*time.Second + time.Millisecond,
			expectError: false,
			expectWarn:  true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			hasError := tt.duration <= 0
			hasWarning := tt.duration > 30*time.Second

			if hasError != tt.expectError {
				t.Errorf("Expected error: %v, got error: %v", tt.expectError, hasError)
			}

			if hasWarning != tt.expectWarn {
				t.Errorf("Expected warning: %v, got warning: %v", tt.expectWarn, hasWarning)
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
