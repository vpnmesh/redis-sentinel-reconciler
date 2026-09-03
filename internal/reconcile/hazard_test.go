package reconcile

import (
	"testing"

	"github.com/vpnmesh/redis-sentinel-reconciler/internal/oracle"
)

func TestFailoverPromoteSafe_H4(t *testing.T) {
	nodes := []oracle.NodeResult{
		{Addr: "10.0.0.1:6379", Role: "master", Writable: true},
		{Addr: "10.0.0.2:6379", Role: "master", Writable: true},
	}
	safe, why := failoverPromoteSafe("10.0.0.2:6379", "10.0.0.1:6379", "master", nodes)
	if safe {
		t.Fatalf("expected unsafe FAILOVER when ads->other writable, why=%s", why)
	}
	if why != "advertised_is_live_writable_not_oracle" {
		t.Fatalf("why=%s", why)
	}

	nodesDown := []oracle.NodeResult{
		{Addr: "10.0.0.1:6379", Role: "master", Writable: true},
		{Addr: "10.0.0.2:6379", Role: "slave", Writable: false},
	}
	safe, why = failoverPromoteSafe("10.0.0.9:6379", "10.0.0.1:6379", "master,s_down", nodesDown)
	if !safe {
		t.Fatalf("expected safe when advertised down, why=%s", why)
	}
}

func TestPreflightMinReachableDisabled(t *testing.T) {
	r := New(Config{
		Apply:             true,
		LocalSentinel:     true,
		HealCooldown:      0,
		MinReachableRedis: -1, // disable
		RedisAddrs:        []string{"10.0.0.1:6379", "10.0.0.2:6379", "10.0.0.3:6379"},
	}, nil)
	nodes := []oracle.NodeResult{
		{Addr: "10.0.0.1:6379"},
		{Addr: "10.0.0.2:6379", Err: contextError{}},
		{Addr: "10.0.0.3:6379", Err: contextError{}},
	}
	if !r.preflightApply("master", nodes) {
		t.Fatal("expected allow when min-reachable disabled")
	}
}

func TestPreflightFailoverInProgress_H6(t *testing.T) {
	r := New(Config{
		Apply:                    true,
		LocalSentinel:            true,
		HealCooldown:             0,
		SkipOnFailoverInProgress: true,
		MinReachableRedis:        -1,
	}, nil)
	if r.preflightApply("master,failover_in_progress", nil) {
		t.Fatal("expected refuse on failover_in_progress")
	}
}
