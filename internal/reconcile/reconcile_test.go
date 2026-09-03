package reconcile

import (
	"testing"

	"github.com/vpnmesh/redis-sentinel-reconciler/internal/oracle"
)

func TestFailoverPromoteSafe(t *testing.T) {
	nodes := []oracle.NodeResult{
		{Addr: "10.0.0.3:6379", Role: "master", Writable: true, RunID: "m"},
		{Addr: "10.0.0.1:6379", Role: "slave", Writable: false, RunID: "s1"},
	}
	ok, why := failoverPromoteSafe("10.255.255.254:6379", "10.0.0.3:6379", "s_down,master", nodes)
	if !ok {
		t.Fatalf("expected safe for s_down advertise, got %v (%s)", ok, why)
	}

	ok, why = failoverPromoteSafe("10.0.0.1:6379", "10.0.0.3:6379", "master", []oracle.NodeResult{
		{Addr: "10.0.0.1:6379", Role: "master", Writable: true, RunID: "wrong"},
		{Addr: "10.0.0.3:6379", Role: "master", Writable: true, RunID: "m"},
	})
	if ok {
		t.Fatalf("expected unsafe when advertised is live writable != oracle, why=%s", why)
	}

	// Equal-epoch hole: flags say s_down,master but the advertised node is a live slave.
	ok, why = failoverPromoteSafe("10.0.0.1:6379", "10.0.0.3:6379", "s_down,master", nodes)
	if ok {
		t.Fatalf("expected unsafe when advertised is live slave, why=%s", why)
	}
	if why != "advertised_is_live_non_oracle" {
		t.Fatalf("why=%s", why)
	}
}

func TestSentinelAuthAfterMonitor(t *testing.T) {
	got := sentinelAuthAfterMonitor("rsr", "s3cret")
	if len(got) != 2 || got[0][0] != "auth-user" || got[0][1] != "rsr" || got[1][0] != "auth-pass" || got[1][1] != "s3cret" {
		t.Fatalf("got %#v", got)
	}
	passOnly := sentinelAuthAfterMonitor("", "p")
	if len(passOnly) != 1 || passOnly[0][0] != "auth-pass" {
		t.Fatalf("pass-only %#v", passOnly)
	}
	userOnly := sentinelAuthAfterMonitor("rsr", "")
	if len(userOnly) != 1 || userOnly[0][0] != "auth-user" {
		t.Fatalf("user-only %#v", userOnly)
	}
	if sentinelAuthAfterMonitor("", "") != nil {
		t.Fatal("empty")
	}
}

func TestEndpointIPPortLiteral(t *testing.T) {
	ip, port, err := endpointIPPort("172.27.0.3:6379")
	if err != nil || ip != "172.27.0.3" || port != 6379 {
		t.Fatalf("got %s:%d err=%v", ip, port, err)
	}
}
