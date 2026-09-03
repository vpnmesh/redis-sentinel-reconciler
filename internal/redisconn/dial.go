package redisconn

import (
	"crypto/tls"
	"time"

	"github.com/redis/go-redis/v9"
)

// Dial is how this process talks to Redis or Sentinel (password, ACL user, TLS).
type Dial struct {
	Addr     string
	Username string
	Password string
	// TLS is a template (no ServerName). Client clones it per dial.
	TLS *tls.Config
	// TLSServerName is SNI only when Addr's host is an IP. Hostname
	// dials use the name in Addr. Same as --tls-server-name / RSR_TLS_SERVER_NAME.
	TLSServerName string
	Timeout       time.Duration
}

// Client returns a go-redis client. Caller must Close it.
func Client(d Dial) *redis.Client {
	timeout := d.Timeout
	if timeout <= 0 {
		timeout = 3 * time.Second
	}
	return redis.NewClient(&redis.Options{
		Addr:         d.Addr,
		Username:     d.Username,
		Password:     d.Password,
		TLSConfig:    CloneForAddr(d.TLS, d.Addr, d.TLSServerName),
		DialTimeout:  timeout,
		ReadTimeout:  timeout,
		WriteTimeout: timeout,
	})
}
