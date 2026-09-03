package reconcile

import (
	"context"
	"fmt"
	"os"
	"time"

	"github.com/vpnmesh/redis-sentinel-reconciler/internal/redisconn"
)

// acquireHealLease tries SET NX EX on the writable oracle (R10).
// Returns true if this process holds the lease (or leasing disabled).
func acquireHealLease(ctx context.Context, oracleAddr, masterName, holder string, ttl time.Duration, dial redisconn.Dial) (bool, error) {
	if ttl <= 0 {
		ttl = 15 * time.Minute
	}
	if holder == "" {
		h, _ := os.Hostname()
		holder = h
		if holder == "" {
			holder = fmt.Sprintf("pid-%d", os.Getpid())
		}
	}
	key := "rsr:heal-lease:" + masterName
	dial.Addr = oracleAddr
	if dial.Timeout <= 0 {
		dial.Timeout = 2 * time.Second
	}
	rdb := redisconn.Client(dial)
	defer rdb.Close()

	ok, err := rdb.SetNX(ctx, key, holder, ttl).Result()
	if err != nil {
		return false, err
	}
	if ok {
		return true, nil
	}
	cur, _ := rdb.Get(ctx, key).Result()
	if cur == holder {
		// Refresh TTL for same holder (restart-safe same hostname).
		_ = rdb.Expire(ctx, key, ttl).Err()
		return true, nil
	}
	return false, nil
}
