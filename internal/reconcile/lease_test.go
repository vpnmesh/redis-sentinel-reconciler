package reconcile

import (
	"context"
	"testing"
	"time"

	"github.com/vpnmesh/redis-sentinel-reconciler/internal/redisconn"
)

func TestAcquireHealLeaseDisabledPath(t *testing.T) {
	// Without a live Redis, dial fails - treat as error path covered by callers.
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	ok, err := acquireHealLease(ctx, "127.0.0.1:1", "mymaster", "t", time.Second, redisconn.Dial{})
	if err == nil && ok {
		t.Fatal("expected fail against closed port")
	}
}
