package reconcile

import (
	"testing"
	"time"

	"github.com/vpnmesh/redis-sentinel-reconciler/internal/oracle"
)

func TestFailoverInProgress(t *testing.T) {
	if !failoverInProgress("master,failover_in_progress") {
		t.Fatal("expected failover_in_progress")
	}
	if failoverInProgress("master") {
		t.Fatal("plain master should be ok")
	}
}

func TestCountReachableSeeds(t *testing.T) {
	nodes := []oracle.NodeResult{
		{Addr: "10.0.0.1:6379"},
		{Addr: "10.0.0.2:6379", Err: contextError{}},
		{Addr: "10.0.0.3:6379"},
	}
	got := countReachableSeeds([]string{"10.0.0.1:6379", "10.0.0.2:6379", "10.0.0.3:6379"}, nodes)
	if got != 2 {
		t.Fatalf("got %d want 2", got)
	}
}

type contextError struct{}

func (contextError) Error() string { return "dial" }

func TestPreflightCooldown(t *testing.T) {
	r := New(Config{
		Apply:                    true,
		LocalSentinel:            true,
		HealCooldown:             time.Hour,
		SkipOnFailoverInProgress: true,
		RedisAddrs:               []string{"10.0.0.1:6379", "10.0.0.2:6379", "10.0.0.3:6379"},
	}, nil)
	r.lastHeal = time.Now()
	nodes := []oracle.NodeResult{
		{Addr: "10.0.0.1:6379"},
		{Addr: "10.0.0.2:6379"},
		{Addr: "10.0.0.3:6379"},
	}
	if r.preflightApply("master", nodes) {
		t.Fatal("expected cooldown refuse")
	}
}

func TestPreflightPartitionSuspect(t *testing.T) {
	r := New(Config{
		Apply:             true,
		LocalSentinel:     true,
		HealCooldown:      0,
		MinReachableRedis: 2,
		RedisAddrs:        []string{"10.0.0.1:6379", "10.0.0.2:6379", "10.0.0.3:6379"},
	}, nil)
	nodes := []oracle.NodeResult{
		{Addr: "10.0.0.1:6379"},
		{Addr: "10.0.0.2:6379", Err: contextError{}},
		{Addr: "10.0.0.3:6379", Err: contextError{}},
	}
	if r.preflightApply("master", nodes) {
		t.Fatal("expected partition_suspect refuse")
	}
}

func TestPreflightRequireLocal(t *testing.T) {
	r := New(Config{
		Apply:            true,
		LocalSentinel:    false,
		AllowGlobalApply: false,
		HealCooldown:     0,
	}, nil)
	if r.preflightApply("master", nil) {
		t.Fatal("expected apply_requires_local_sentinel")
	}
}
