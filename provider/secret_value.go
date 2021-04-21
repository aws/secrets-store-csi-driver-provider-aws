package provider

// Contains the actual contents of the secret fetched from either Secrete Manager
// or SSM Parameter Store along with the original descriptor.
type SecretValue struct {
	Value      []byte
	Descriptor SecretDescriptor
}

func (p *SecretValue) String() string { return "<REDACTED>" } // Do not log secrets
