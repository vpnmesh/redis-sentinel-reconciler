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
	TLS      *tls.Config
	Timeout  time.Duration
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
		TLSConfig:    d.TLS,
		DialTimeout:  timeout,
		ReadTimeout:  timeout,
		WriteTimeout: timeout,
	})
}
