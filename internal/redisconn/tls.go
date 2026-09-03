package redisconn

import (
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"os"
)

// TLSSettings is the operator-facing TLS knob set (flags / env).
type TLSSettings struct {
	Enabled    bool
	SkipVerify bool
	CAFile     string
	ServerName string
	CertFile   string
	KeyFile    string
}

// BuildTLS returns nil, nil when TLS is off. Fail-fast if files are missing
// or TLS extras are set while TLS itself is disabled.
func BuildTLS(s TLSSettings) (*tls.Config, error) {
	if !s.Enabled {
		if s.CAFile != "" || s.CertFile != "" || s.KeyFile != "" || s.SkipVerify {
			return nil, fmt.Errorf("TLS extras set (ca/cert/skip-verify) but TLS is off; pass --tls or RSR_TLS=true")
		}
		return nil, nil
	}
	if (s.CertFile == "") != (s.KeyFile == "") {
		return nil, fmt.Errorf("--tls-cert and --tls-key must be set together")
	}

	cfg := &tls.Config{
		MinVersion:         tls.VersionTLS12,
		InsecureSkipVerify: s.SkipVerify, //nolint:gosec // operator-opt-in for lab / IP-only certs
		ServerName:         s.ServerName,
	}

	if s.CAFile != "" {
		pem, err := os.ReadFile(s.CAFile)
		if err != nil {
			return nil, fmt.Errorf("read TLS CA file %s: %w", s.CAFile, err)
		}
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM(pem) {
			return nil, fmt.Errorf("TLS CA file %s: no PEM certificates found", s.CAFile)
		}
		cfg.RootCAs = pool
	}

	if s.CertFile != "" {
		cert, err := tls.LoadX509KeyPair(s.CertFile, s.KeyFile)
		if err != nil {
			return nil, fmt.Errorf("load TLS client cert/key: %w", err)
		}
		cfg.Certificates = []tls.Certificate{cert}
	}

	return cfg, nil
}
