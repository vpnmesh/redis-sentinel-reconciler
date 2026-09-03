package redisconn

import (
	"crypto/tls"
	"net"
)

// CloneForAddr returns a per-dial tls.Config. Concurrent probes must not
// share a mutable ServerName on the template.
//
// SNI:
//   - hostname in addr → that hostname (operator --tls-server-name is ignored)
//   - IP in addr → ipFallbackSNI (operator --tls-server-name), or empty
//
// Prefer dialing the DNS name on the certificate. ipFallbackSNI exists for
// the leftover case of talking to 127.0.0.1 with a hostname cert (no IP SAN).
func CloneForAddr(base *tls.Config, addr, ipFallbackSNI string) *tls.Config {
	if base == nil {
		return nil
	}
	cfg := base.Clone()
	host := addrHost(addr)
	if ip := net.ParseIP(host); ip != nil {
		cfg.ServerName = ipFallbackSNI
		return cfg
	}
	cfg.ServerName = host
	return cfg
}

func addrHost(addr string) string {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return addr
	}
	return host
}
