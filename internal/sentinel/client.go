package sentinel

import (
	"context"
	"fmt"
	"net"
	"strconv"

	"github.com/redis/go-redis/v9"
	"github.com/vpnmesh/redis-sentinel-reconciler/internal/redisconn"
)

// Dial is redisconn.Dial scoped to a Sentinel endpoint.
type Dial = redisconn.Dial

// Client talks to a single Redis Sentinel instance via the Redis protocol.
type Client struct {
	addr string
	rdb  *redis.Client
}

// NewClient dials a Sentinel at host:port (no TLS). Prefer New for TLS/ACL.
func NewClient(addr, password string) *Client {
	return New(redisconn.Dial{Addr: addr, Password: password})
}

// New dials Sentinel with optional TLS and ACL username.
func New(d redisconn.Dial) *Client {
	return &Client{addr: d.Addr, rdb: redisconn.Client(d)}
}

// Addr returns the configured Sentinel address.
func (c *Client) Addr() string { return c.addr }

// Close releases the connection.
func (c *Client) Close() error { return c.rdb.Close() }

// GetMasterAddrByName returns the master host and port advertised by this Sentinel.
func (c *Client) GetMasterAddrByName(ctx context.Context, name string) (host string, port int, err error) {
	val, err := c.rdb.Do(ctx, "SENTINEL", "get-master-addr-by-name", name).StringSlice()
	if err != nil {
		return "", 0, err
	}
	if len(val) != 2 {
		return "", 0, fmt.Errorf("sentinel %s: unexpected get-master-addr response: %v", c.addr, val)
	}
	p, err := strconv.Atoi(val[1])
	if err != nil {
		return "", 0, fmt.Errorf("sentinel %s: invalid master port %q: %w", c.addr, val[1], err)
	}
	return val[0], p, nil
}

// Master returns SENTINEL master <name> as a string map.
func (c *Client) Master(ctx context.Context, name string) (map[string]string, error) {
	val, err := c.rdb.Do(ctx, "SENTINEL", "master", name).StringSlice()
	if err != nil {
		return nil, err
	}
	return kvSliceToMap(val)
}

// Replicas returns SENTINEL replicas <name> as a slice of string maps.
func (c *Client) Replicas(ctx context.Context, name string) ([]map[string]string, error) {
	raw, err := c.rdb.Do(ctx, "SENTINEL", "replicas", name).Slice()
	if err != nil {
		return nil, err
	}
	out := make([]map[string]string, 0, len(raw))
	for _, item := range raw {
		kv, err := kvSliceToMap(toStringSlice(item))
		if err != nil {
			return nil, err
		}
		out = append(out, kv)
	}
	return out, nil
}

// Sentinels returns SENTINEL sentinels <name> as a slice of string maps.
func (c *Client) Sentinels(ctx context.Context, name string) ([]map[string]string, error) {
	raw, err := c.rdb.Do(ctx, "SENTINEL", "sentinels", name).Slice()
	if err != nil {
		return nil, err
	}
	out := make([]map[string]string, 0, len(raw))
	for _, item := range raw {
		kv, err := kvSliceToMap(toStringSlice(item))
		if err != nil {
			return nil, err
		}
		out = append(out, kv)
	}
	return out, nil
}

// Failover forces SENTINEL FAILOVER <name> on this Sentinel.
func (c *Client) Failover(ctx context.Context, name string) error {
	return c.rdb.Do(ctx, "SENTINEL", "failover", name).Err()
}

// Reset runs SENTINEL RESET <pattern> (clears master state; peers may re-teach via Hello).
func (c *Client) Reset(ctx context.Context, pattern string) error {
	return c.rdb.Do(ctx, "SENTINEL", "reset", pattern).Err()
}

// Remove runs SENTINEL REMOVE <name>.
func (c *Client) Remove(ctx context.Context, name string) error {
	return c.rdb.Do(ctx, "SENTINEL", "remove", name).Err()
}

// Monitor runs SENTINEL MONITOR <name> <ip> <port> <quorum>.
func (c *Client) Monitor(ctx context.Context, name, ip string, port, quorum int) error {
	return c.rdb.Do(ctx, "SENTINEL", "monitor", name, ip, port, quorum).Err()
}

// SetQuorum runs SENTINEL SET <name> quorum <n>.
func (c *Client) SetQuorum(ctx context.Context, name string, quorum int) error {
	return c.rdb.Do(ctx, "SENTINEL", "set", name, "quorum", quorum).Err()
}

// Set runs SENTINEL SET <name> <option> <value> (e.g. auth-pass).
func (c *Client) Set(ctx context.Context, name, option, value string) error {
	return c.rdb.Do(ctx, "SENTINEL", "set", name, option, value).Err()
}

// RedisAddrFromInfo extracts host:port from a SENTINEL master/replica map.
func RedisAddrFromInfo(info map[string]string) string {
	if addr := info["addr"]; addr != "" {
		if _, _, err := net.SplitHostPort(addr); err == nil {
			return addr
		}
	}
	ip := info["ip"]
	port := info["port"]
	if ip == "" || port == "" {
		return ""
	}
	return net.JoinHostPort(ip, port)
}

func kvSliceToMap(val []string) (map[string]string, error) {
	if len(val)%2 != 0 {
		return nil, fmt.Errorf("odd key/value slice length %d", len(val))
	}
	m := make(map[string]string, len(val)/2)
	for i := 0; i < len(val); i += 2 {
		m[val[i]] = val[i+1]
	}
	return m, nil
}

func parseKVSlice(val []string, err error) (map[string]string, error) {
	if err != nil {
		return nil, err
	}
	return kvSliceToMap(val)
}

func toStringSlice(v interface{}) []string {
	switch arr := v.(type) {
	case []interface{}:
		out := make([]string, len(arr))
		for i, x := range arr {
			out[i] = fmt.Sprint(x)
		}
		return out
	case []string:
		return arr
	default:
		return nil
	}
}
