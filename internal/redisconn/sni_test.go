package redisconn

import (
	"crypto/tls"
	"net"
	"os"
	"path/filepath"
	"sync"
	"testing"
)

func TestCloneForAddr_HostnameIgnoresIPFallback(t *testing.T) {
	base, err := BuildTLS(TLSSettings{Enabled: true, SkipVerify: true})
	if err != nil {
		t.Fatal(err)
	}
	got := CloneForAddr(base, "db-n2.example.com:6379", "db-n1.example.com")
	if got.ServerName != "db-n2.example.com" {
		t.Fatalf("hostname dial must use addr SNI, got %q", got.ServerName)
	}
	if base.ServerName != "" {
		t.Fatalf("template mutated: %q", base.ServerName)
	}
}

func TestCloneForAddr_IPUsesFallback(t *testing.T) {
	base, err := BuildTLS(TLSSettings{Enabled: true, SkipVerify: true})
	if err != nil {
		t.Fatal(err)
	}
	got := CloneForAddr(base, "127.0.0.1:26379", "db-n1.example.com")
	if got.ServerName != "db-n1.example.com" {
		t.Fatalf("IP dial SNI=%q", got.ServerName)
	}
	empty := CloneForAddr(base, "10.0.0.9:6379", "")
	if empty.ServerName != "" {
		t.Fatalf("IP without fallback should leave SNI empty, got %q", empty.ServerName)
	}
	v6 := CloneForAddr(base, "[::1]:26379", "db-n1.example.com")
	if v6.ServerName != "db-n1.example.com" {
		t.Fatalf("IPv6 dial SNI=%q", v6.ServerName)
	}
}

func TestCloneForAddr_ConcurrentDoesNotRace(t *testing.T) {
	base, err := BuildTLS(TLSSettings{Enabled: true, SkipVerify: true})
	if err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	errCh := make(chan string, 64)
	for i := 0; i < 32; i++ {
		wg.Add(2)
		go func() {
			defer wg.Done()
			c := CloneForAddr(base, "a.example.com:26379", "ip-sni")
			if c.ServerName != "a.example.com" {
				errCh <- "host SNI " + c.ServerName
			}
		}()
		go func() {
			defer wg.Done()
			c := CloneForAddr(base, "127.0.0.1:26379", "ip-sni")
			if c.ServerName != "ip-sni" {
				errCh <- "ip SNI " + c.ServerName
			}
		}()
	}
	wg.Wait()
	close(errCh)
	for msg := range errCh {
		t.Fatal(msg)
	}
	if base.ServerName != "" {
		t.Fatalf("template mutated: %q", base.ServerName)
	}
}

func TestPerDialSNI_IPAndHostnamesVerify(t *testing.T) {
	dir := t.TempDir()
	caPEM, caKey := mustTestCA(t)
	caFile := filepath.Join(dir, "ca.pem")
	if err := os.WriteFile(caFile, caPEM, 0o600); err != nil {
		t.Fatal(err)
	}

	n1 := serveTLS(t, mustLeafDNSOnly(t, caPEM, caKey, 11, "db-n1.example.com"))
	defer n1.Close()
	n2 := serveTLS(t, mustLeafDNSOnly(t, caPEM, caKey, 12, "db-n2.example.com"))
	defer n2.Close()

	base, err := BuildTLS(TLSSettings{Enabled: true, CAFile: caFile})
	if err != nil {
		t.Fatal(err)
	}
	if base.InsecureSkipVerify {
		t.Fatal("verify must stay on")
	}

	// Local Sentinel: dial 127.0.0.1, cert SAN is the node DNS name (no IP SAN).
	sniLocal := CloneForAddr(base, "127.0.0.1:26379", "db-n1.example.com")
	if sniLocal.ServerName != "db-n1.example.com" {
		t.Fatalf("local IP SNI=%q", sniLocal.ServerName)
	}
	c1, err := tls.Dial("tcp", n1.Addr().String(), sniLocal)
	if err != nil {
		t.Fatalf("127.0.0.1 dial with per-dial SNI=db-n1 failed: %v", err)
	}
	_ = c1.Close()

	// Other node: hostname from the dial address; global fallback must not win.
	sniPeer := CloneForAddr(base, "db-n2.example.com:6379", "db-n1.example.com")
	if sniPeer.ServerName != "db-n2.example.com" {
		t.Fatalf("peer SNI=%q (global fallback must not apply to hostnames)", sniPeer.ServerName)
	}
	c2, err := tls.Dial("tcp", n2.Addr().String(), sniPeer)
	if err != nil {
		t.Fatalf("hostname dial db-n2 failed: %v", err)
	}
	_ = c2.Close()

	// Wrong global-style SNI on the n2 cert must fail (the old one-name bug).
	wrong := CloneForAddr(base, "127.0.0.1:6379", "db-n1.example.com")
	if _, err := tls.Dial("tcp", n2.Addr().String(), wrong); err == nil {
		t.Fatal("n2 cert must not verify under db-n1 SNI")
	}

	// IP dial with no fallback and no IP SAN must fail (do not skip-verify).
	bareIP := CloneForAddr(base, "127.0.0.1:26379", "")
	if _, err := tls.Dial("tcp", n1.Addr().String(), bareIP); err == nil {
		t.Fatal("IP dial without SNI fallback should fail when cert has no IP SAN")
	}
}

func serveTLS(t *testing.T, cert tls.Certificate) net.Listener {
	t.Helper()
	ln, err := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{
		Certificates: []tls.Certificate{cert},
		MinVersion:   tls.VersionTLS12,
	})
	if err != nil {
		t.Fatal(err)
	}
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
	return ln
}
