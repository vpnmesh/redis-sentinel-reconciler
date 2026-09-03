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
}

func TestEndpointIPPortLiteral(t *testing.T) {
	ip, port, err := endpointIPPort("172.27.0.3:6379")
	if err != nil || ip != "172.27.0.3" || port != 6379 {
		t.Fatalf("got %s:%d err=%v", ip, port, err)
	}
}
