package reconcile

import (
	"context"
	"net"
	"strings"
	"testing"

	"github.com/vpnmesh/redis-sentinel-reconciler/internal/oracle"
)

func TestFailoverPromoteSafe(t *testing.T) {
	nodes := []oracle.NodeResult{
		{Addr: "10.0.0.3:6379", Role: "master", Writable: true, RunID: "m"},
		{Addr: "10.0.0.1:6379", Role: "slave", Writable: false, RunID: "s1"},
	}
	ok, why := failoverPromoteSafe("10.255.255.254:6379", "10.0.0.3:6379", "s_down,master", nodes)
	if ok {
		t.Fatalf("FAILOVER must stay unsafe for fake/unreachable ads, got %v (%s)", ok, why)
	}
	if why != reasonAdvertisedUnreachable {
		t.Fatalf("why=%s", why)
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

func TestMonitorHostPort_HostnameNotResolved(t *testing.T) {
	host, port, err := monitorHostPort("n0.redis.invalid:6379")
	if err != nil || host != "n0.redis.invalid" || port != 6379 {
		t.Fatalf("got %s:%d err=%v (LookupIP must not rewrite the seed)", host, port, err)
	}
}

func TestPreferredSeedAddr_IgnoresProbeOrder(t *testing.T) {
	fqdn := "n0.redis.invalid:6379"
	ip := "10.42.1.5:6379"
	seeds := []string{"10.42.1.5:6379", fqdn, "n1.redis.invalid:6379"}
	orders := [][]oracle.NodeResult{
		{
			{Addr: ip, Role: "master", Writable: true, RunID: "n0"},
			{Addr: fqdn, Role: "master", Writable: true, RunID: "n0"},
		},
		{
			{Addr: fqdn, Role: "master", Writable: true, RunID: "n0"},
			{Addr: ip, Role: "master", Writable: true, RunID: "n0"},
		},
	}
	for _, nodes := range orders {
		w, count := oracle.ClassifyWritable(nodes)
		if count != 1 || w == nil {
			t.Fatalf("count=%d writable=%v", count, w)
		}
		if got := preferredSeedAddr(w, nodes, seeds); got != fqdn {
			t.Fatalf("writable %s → MONITOR %s, want %s", w.Addr, got, fqdn)
		}
	}
}

func TestClassifyDiverge_FormVsMaster(t *testing.T) {
	fqdn := "n0.redis.invalid:6379"
	ip := "10.42.1.5:6379"
	nodes := []oracle.NodeResult{
		{Addr: ip, Role: "master", Writable: true, RunID: "n0"},
		{Addr: fqdn, Role: "master", Writable: true, RunID: "n0"},
		{Addr: "10.0.0.9:6379", Role: "master", Writable: true, RunID: "other"},
	}
	w := &nodes[0]
	if classifyDiverge(ip, w.Addr, fqdn, w, nodes) != divergeForm {
		t.Fatal("advertised IP + seed hostname for the same run_id is address form")
	}
	if classifyDiverge(fqdn, ip, fqdn, w, nodes) != divergeNoop {
		t.Fatal("advertised seed hostname must noop")
	}
	if classifyDiverge("10.0.0.9:6379", ip, fqdn, w, nodes) != divergeMaster {
		t.Fatal("different run_id stays on the master-change path")
	}
	if classifyDiverge(ip, ip, ip, w, []oracle.NodeResult{*w}) != divergeNoop {
		t.Fatal("IP seed matching the advertisement must noop")
	}
}

func TestSameRedisEndpoint_IPIdentityUnchanged(t *testing.T) {
	if !sameRedisEndpoint("10.0.0.2:6379", "10.0.0.2:6379") {
		t.Fatal("identical IPs must match")
	}
	if sameRedisEndpoint("10.0.0.2:6379", "10.0.0.1:6379") {
		t.Fatal("distinct IPs must not match")
	}
}

func TestClassifyDiverge_ResolvedIPIsFormNotNoop(t *testing.T) {
	if !sameRedisEndpoint("127.0.0.1:6379", "localhost:6379") {
		t.Fatal("precondition: localhost must resolve to 127.0.0.1")
	}
	nodes := []oracle.NodeResult{
		{Addr: "127.0.0.1:6379", Role: "master", Writable: true, RunID: "n0"},
		{Addr: "localhost:6379", Role: "master", Writable: true, RunID: "n0"},
	}
	w := &nodes[0]
	if classifyDiverge("127.0.0.1:6379", w.Addr, "localhost:6379", w, nodes) != divergeForm {
		t.Fatal("DNS-equal pod IP and seed hostname must be address form, not noop")
	}
	if classifyDiverge("localhost:6379", "127.0.0.1:6379", "localhost:6379", w, nodes) != divergeNoop {
		t.Fatal("advertised seed hostname must noop even when masterKey is the IP")
	}
}

func TestClassifyDiverge_DifferentRunIDNotMergedByDNS(t *testing.T) {
	if !sameRedisEndpoint("127.0.0.1:6379", "localhost:6379") {
		t.Fatal("precondition: localhost must resolve to 127.0.0.1")
	}
	nodes := []oracle.NodeResult{
		{Addr: "127.0.0.1:6379", Role: "master", Writable: true, RunID: "a"},
		{Addr: "localhost:6379", Role: "master", Writable: true, RunID: "b"},
	}
	_, n := oracle.ClassifyWritable(nodes)
	if n != 2 {
		t.Fatalf("different run_ids must stay dual_master, count=%d", n)
	}
	w := &nodes[0]
	if classifyDiverge("localhost:6379", w.Addr, "127.0.0.1:6379", w, nodes) != divergeMaster {
		t.Fatal("DNS must not turn a different run_id into noop or address form")
	}
	same := []oracle.NodeResult{
		{Addr: "127.0.0.1:6379", Role: "master", Writable: true, RunID: "a"},
		{Addr: "localhost:6379", Role: "master", Writable: true, RunID: "a"},
	}
	if _, n := oracle.ClassifyWritable(same); n != 1 {
		t.Fatalf("same run_id must be one master, count=%d", n)
	}
}

func TestAddrEqual_TrailingDotCaseIPv6Port(t *testing.T) {
	if !addrEqual("db.example.:6379", "db.example:6379") {
		t.Fatal("trailing dot is the same host")
	}
	if !addrEqual("DB.Example:6379", "db.example:6379") {
		t.Fatal("host compare is case-insensitive")
	}
	if !addrEqual("db.example:6379", "db.example:06379") {
		t.Fatal("leading-zero port is the same port")
	}
	if addrEqual("db.example:6379", "db.example:6380") {
		t.Fatal("different ports must not match")
	}
	if !addrEqual("[2001:db8::1]:6379", "[2001:db8:0:0:0:0:0:1]:6379") {
		t.Fatal("IPv6 textual forms of one address must match")
	}
	if addrEqual("[2001:db8::1]:6379", "[2001:db8::2]:6379") {
		t.Fatal("distinct IPv6 addresses must not match")
	}
	if hostnameForm("2001:db8::1:6379") {
		t.Fatal("unbracketed IPv6 must not be treated as a hostname")
	}
	if masterAddr("2001:db8::1", 6379) != "[2001:db8::1]:6379" {
		t.Fatalf("masterAddr %s", masterAddr("2001:db8::1", 6379))
	}
}

func TestVerifyAdvertised_HostnameDoesNotAcceptIP(t *testing.T) {
	r := testHealReconciler(nil)
	c := &fakeSentinel{adHost: "127.0.0.1", adPort: 6379}
	if r.verifyAdvertised(context.Background(), c, "localhost:6379") {
		t.Fatal("hostname verify must not accept the resolved pod IP")
	}
	c.adHost = "db.example"
	if !r.verifyAdvertised(context.Background(), c, "db.example.:6379") {
		t.Fatal("trailing dot on the seed must still verify")
	}
	c.adHost = "DB.Example"
	if !r.verifyAdvertised(context.Background(), c, "db.example:6379") {
		t.Fatal("case difference must still verify")
	}
	c.adHost = "2001:db8::1"
	if !r.verifyAdvertised(context.Background(), c, "[2001:db8::1]:6379") {
		t.Fatal("IPv6 echo without brackets must verify against the bracketed seed")
	}
	c.adHost = "2001:db8::1"
	if r.verifyAdvertised(context.Background(), c, "db.example:6379") {
		t.Fatal("hostname verify must not accept an IPv6 echo")
	}
}

func TestPreferredSeedAddr_PortCaseOrderAndAAAA(t *testing.T) {
	if got := healDialAddr("n0.example:6379", "10.0.0.1:6379"); got != "n0.example:6379" {
		t.Fatalf("dial %s", got)
	}
	if got := healDialAddr("", "10.0.0.1:6379"); got != "10.0.0.1:6379" {
		t.Fatalf("dial fallback %s", got)
	}

	v4 := "127.0.0.1:6379"
	nodes := []oracle.NodeResult{
		{Addr: v4, Role: "master", Writable: true, RunID: "n0"},
		{Addr: "localhost:6379", Role: "master", Writable: true, RunID: "n0"},
	}
	orders := [][]oracle.NodeResult{nodes, {nodes[1], nodes[0]}}
	for _, list := range orders {
		w, n := oracle.ClassifyWritable(list)
		if n != 1 || w == nil {
			t.Fatalf("count=%d", n)
		}
		if got := preferredSeedAddr(w, list, []string{v4, "LocalHost:6379"}); got != "LocalHost:6379" {
			t.Fatalf("writable %s → %s", w.Addr, got)
		}
	}
	w := &nodes[0]
	if got := preferredSeedAddr(w, nodes, []string{"localhost:6380", v4}); got != v4 {
		t.Fatalf("port mismatch picked %s", got)
	}

	prev := netLookupIP
	netLookupIP = func(host string) ([]net.IP, error) {
		switch strings.TrimRight(host, ".") {
		case "dual.example":
			return []net.IP{net.ParseIP("10.9.9.9"), net.ParseIP("2001:db8::9")}, nil
		case "other.example":
			return []net.IP{net.ParseIP("10.9.9.9")}, nil
		default:
			return net.LookupIP(host)
		}
	}
	t.Cleanup(func() { netLookupIP = prev })

	v6 := "[2001:db8::9]:6379"
	onlyV6 := []oracle.NodeResult{{Addr: v6, Role: "master", Writable: true, RunID: "n0"}}
	vw := &onlyV6[0]
	if got := preferredSeedAddr(vw, onlyV6, []string{"other.example:6379", "10.9.9.9:6379", "dual.example:6379"}); got != "dual.example:6379" {
		t.Fatalf("AAAA hidden by A, got %s", got)
	}
	if got := preferredSeedAddr(vw, onlyV6, []string{"dual.example:6380", v6}); got != v6 {
		t.Fatalf("AAAA port mismatch picked %s", got)
	}
	mon := preferredSeedAddr(vw, onlyV6, []string{"dual.example:6379"})
	if classifyDiverge(v6, vw.Addr, mon, vw, onlyV6) != divergeForm {
		t.Fatalf("monitor %s must be address form against the IPv6 ad", mon)
	}

	split := []oracle.NodeResult{
		{Addr: v6, Role: "master", Writable: true, RunID: "n0"},
		{Addr: "dual.example:6379", Role: "master", Writable: true, RunID: "other"},
	}
	sw := &split[0]
	got := preferredSeedAddr(sw, split, []string{"dual.example:6379"})
	if got != v6 {
		t.Fatalf("different run_id hostname selected: %s", got)
	}
	if classifyDiverge(v6, sw.Addr, got, sw, split) != divergeNoop {
		t.Fatal("IPv6 ad of this master must not be rewritten onto the other run_id")
	}
	if classifyDiverge("dual.example:6379", sw.Addr, got, sw, split) != divergeMaster {
		t.Fatal("the other run_id's hostname stays on the master-change path")
	}
}
