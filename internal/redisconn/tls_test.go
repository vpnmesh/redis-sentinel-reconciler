package redisconn

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestBuildTLS_Disabled(t *testing.T) {
	cfg, err := BuildTLS(TLSSettings{})
	if err != nil || cfg != nil {
		t.Fatalf("off -> nil,nil; got cfg=%v err=%v", cfg, err)
	}
}

func TestBuildTLS_ExtrasWithoutEnable(t *testing.T) {
	if _, err := BuildTLS(TLSSettings{SkipVerify: true}); err == nil {
		t.Fatal("expected error when skip-verify set without --tls")
	}
	if _, err := BuildTLS(TLSSettings{CAFile: "/tmp/x.pem"}); err == nil {
		t.Fatal("expected error when CA set without --tls")
	}
}

func TestBuildTLS_SkipVerify(t *testing.T) {
	cfg, err := BuildTLS(TLSSettings{Enabled: true, SkipVerify: true})
	if err != nil {
		t.Fatal(err)
	}
	if cfg == nil || !cfg.InsecureSkipVerify || cfg.MinVersion != tls.VersionTLS12 {
		t.Fatalf("unexpected cfg: %#v", cfg)
	}
}

func TestBuildTLS_CAFileMissing(t *testing.T) {
	_, err := BuildTLS(TLSSettings{Enabled: true, CAFile: filepath.Join(t.TempDir(), "nope.pem")})
	if err == nil {
		t.Fatal("expected read error")
	}
}

func TestBuildTLS_CAFileEmptyPEM(t *testing.T) {
	p := filepath.Join(t.TempDir(), "empty.pem")
	if err := os.WriteFile(p, []byte("not a cert\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := BuildTLS(TLSSettings{Enabled: true, CAFile: p}); err == nil {
		t.Fatal("expected PEM parse error")
	}
}

func TestBuildTLS_CertWithoutKey(t *testing.T) {
	if _, err := BuildTLS(TLSSettings{Enabled: true, CertFile: "a.pem"}); err == nil {
		t.Fatal("expected cert/key pair error")
	}
}

func TestBuildTLS_CAVerifiesHandshake(t *testing.T) {
	dir := t.TempDir()
	caPEM, caKey := mustTestCA(t)
	caFile := filepath.Join(dir, "ca.pem")
	if err := os.WriteFile(caFile, caPEM, 0o600); err != nil {
		t.Fatal(err)
	}

	leafCert := mustLeaf(t, caPEM, caKey, "redis.test")
	ln, err := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{
		Certificates: []tls.Certificate{leafCert},
		MinVersion:   tls.VersionTLS12,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()

	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				tc, ok := c.(*tls.Conn)
				if !ok {
					return
				}
				_ = tc.Handshake()
				_, _ = tc.Read(make([]byte, 1))
			}(c)
		}
	}()

	clientTLS, err := BuildTLS(TLSSettings{
		Enabled:    true,
		CAFile:     caFile,
		ServerName: "redis.test",
	})
	if err != nil {
		t.Fatal(err)
	}

	conn, err := tls.Dial("tcp", ln.Addr().String(), clientTLS)
	if err != nil {
		t.Fatalf("trusted CA handshake failed: %v", err)
	}
	_ = conn.Close()

	bad, err := BuildTLS(TLSSettings{Enabled: true, ServerName: "redis.test"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := tls.Dial("tcp", ln.Addr().String(), bad); err == nil {
		t.Fatal("system-roots (no CA file) should reject the test CA cert")
	}
}

func mustTestCA(t *testing.T) ([]byte, *ecdsa.PrivateKey) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "rsr-test-ca"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(24 * time.Hour),
		IsCA:                  true,
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature,
		BasicConstraintsValid: true,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), key
}

func mustLeaf(t *testing.T, caPEM []byte, caKey *ecdsa.PrivateKey, dnsName string) tls.Certificate {
	t.Helper()
	block, _ := pem.Decode(caPEM)
	caCert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		t.Fatal(err)
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(2),
		Subject:      pkix.Name{CommonName: dnsName},
		DNSNames:     []string{dnsName},
		IPAddresses:  []net.IP{net.ParseIP("127.0.0.1")},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, caCert, &key.PublicKey, caKey)
	if err != nil {
		t.Fatal(err)
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER})
	pair, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		t.Fatal(err)
	}
	return pair
}
