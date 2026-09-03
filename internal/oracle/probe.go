package oracle

import (
	"context"
	"fmt"
	"net"
	"strconv"
	"strings"
	"time"

	"github.com/redis/go-redis/v9"
	"github.com/vpnmesh/redis-sentinel-reconciler/internal/redisconn"
)

const ProbeKey = "rsr:probe"

// NodeResult is the outcome of probing a single Redis node.
type NodeResult struct {
	Addr       string
	Role       string
	Writable   bool
	MasterHost string
	MasterPort int
	RunID      string
	Err        error
}

// AddrKey returns host:port for comparison.
func (n NodeResult) AddrKey() string { return n.Addr }

// MasterKey returns the upstream master as host:port when role is slave.
func (n NodeResult) MasterKey() string {
	if n.MasterHost == "" || n.MasterPort == 0 {
		return ""
	}
	return fmt.Sprintf("%s:%d", n.MasterHost, n.MasterPort)
}

// Dial is how Probe talks to a Redis node (password, ACL user, TLS).
type Dial = redisconn.Dial

// Probe connects to addr, runs ROLE and a short-lived SET probe.
func Probe(ctx context.Context, addr, password string) NodeResult {
	return ProbeDial(ctx, addr, Dial{Password: password, Timeout: 3 * time.Second})
}

// ProbeTimeout is Probe with a custom dial/read/write timeout (use short for untrusted ads).
func ProbeTimeout(ctx context.Context, addr, password string, timeout time.Duration) NodeResult {
	return ProbeDial(ctx, addr, Dial{Password: password, Timeout: timeout})
}

// ProbeDial is Probe with full dial options (TLS / ACL).
func ProbeDial(ctx context.Context, addr string, d Dial) NodeResult {
	if d.Timeout <= 0 {
		d.Timeout = 3 * time.Second
	}
	res := NodeResult{Addr: addr}
	d.Addr = addr
	rdb := redisconn.Client(d)
	defer rdb.Close()

	roleVal, err := rdb.Do(ctx, "ROLE").Slice()
	if err != nil {
		res.Err = err
		return res
	}
	if len(roleVal) == 0 {
		res.Err = fmt.Errorf("empty ROLE response")
		return res
	}
	res.Role = fmt.Sprint(roleVal[0])

	if info, err := rdb.Info(ctx, "server").Result(); err == nil {
		for _, line := range strings.Split(info, "\n") {
			line = strings.TrimSpace(line)
			if strings.HasPrefix(line, "run_id:") {
				res.RunID = strings.TrimPrefix(line, "run_id:")
				break
			}
		}
	}

	switch res.Role {
	case "master":
		res.Writable = trySet(ctx, rdb)
	case "slave":
		if len(roleVal) >= 3 {
			res.MasterHost = fmt.Sprint(roleVal[1])
			switch p := roleVal[2].(type) {
			case int64:
				res.MasterPort = int(p)
			case string:
				res.MasterPort, _ = strconv.Atoi(p)
			default:
				res.MasterPort, _ = strconv.Atoi(fmt.Sprint(p))
			}
		}
		res.Writable = trySet(ctx, rdb)
	default:
		res.Writable = false
	}
	return res
}

func trySet(ctx context.Context, rdb *redis.Client) bool {
	err := rdb.Set(ctx, ProbeKey, time.Now().Unix(), 5*time.Second).Err()
	if err == nil {
		return true
	}
	if strings.Contains(strings.ToUpper(err.Error()), "READONLY") {
		return false
	}
	return false
}

// ClassifyWritable counts distinct writable masters (dedupe by run_id / resolved IP).
func ClassifyWritable(nodes []NodeResult) (writable *NodeResult, count int) {
	seen := map[string]struct{}{}
	for i := range nodes {
		n := &nodes[i]
		if n.Err != nil || n.Role != "master" || !n.Writable {
			continue
		}
		key := identityKey(n)
		if _, ok := seen[key]; ok {
			continue
		}
		seen[key] = struct{}{}
		count++
		if writable == nil {
			writable = n
		}
	}
	return writable, count
}

func identityKey(n *NodeResult) string {
	if n.RunID != "" {
		return "run:" + n.RunID
	}
	host, port, err := net.SplitHostPort(n.Addr)
	if err != nil {
		return n.Addr
	}
	ips, err := net.LookupIP(host)
	if err != nil || len(ips) == 0 {
		return n.Addr
	}
	return net.JoinHostPort(ips[0].String(), port)
}
