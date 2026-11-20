package reconcile

import (
	"context"
	"errors"
	"net"
	"strconv"
	"testing"

	"github.com/vpnmesh/redis-sentinel-reconciler/internal/oracle"
)

// Production split: unique writable n2; n1 Sentinel ads n1 as s_down,master;
// Redis n1 is ROLE slave; same config-epoch; APPLY + equal_epoch_escalate=true.
func productionStaleReplicaNodes() (advertised, oracleAddr, flags string, nodes []oracle.NodeResult) {
	return "10.0.0.1:6379", "10.0.0.2:6379", "s_down,master", []oracle.NodeResult{
		{Addr: "10.0.0.1:6379", Role: "slave", Writable: false, RunID: "n1"},
		{Addr: "10.0.0.2:6379", Role: "master", Writable: true, RunID: "n2"},
		{Addr: "10.0.0.3:6379", Role: "slave", Writable: false, RunID: "n3"},
	}
}

func TestPlanApplyHeal_ProductionStaleReplica_MonitorsUnderDefaultEscalate(t *testing.T) {
	advertised, oracleAddr, flags, nodes := productionStaleReplicaNodes()
	safe, why := failoverPromoteSafe(advertised, oracleAddr, flags, nodes)
	if safe {
		t.Fatalf("FAILOVER must stay unsafe, why=%s", why)
	}
	if why != reasonLiveNonOracle {
		t.Fatalf("why=%s", why)
	}
	plan := planApplyHeal(1, safe, why, true, true) // equal_epoch_escalate default
	if plan.Action != actionMonitor {
		t.Fatalf("v0.1.1 refused MONITOR here (action=%s reason=%s); MONITOR is the API heal", plan.Action, plan.Reason)
	}
}

func TestPlanApplyHeal_v011WouldRefuseThisSplit(t *testing.T) {
	// Reproduce the v0.1.1 gate: equal-epoch + any unsafe FAILOVER refuses MONITOR.
	safe, why := false, reasonLiveNonOracle
	v011Refuse := true && !safe // equalEpochEscalate && !failoverSafe
	if !v011Refuse {
		t.Fatal("sanity")
	}
	plan := planApplyHeal(1, safe, why, true, true)
	if plan.Action == actionRefuse {
		t.Fatal("product must not keep the v0.1.1 refuse for a live-replica stale ad")
	}
}

func TestPlanApplyHeal_DualWritableRefusesBoth(t *testing.T) {
	plan := planApplyHeal(2, false, reasonLiveWritableNotOracle, true, true)
	if plan.Action != actionRefuse || plan.Reason != reasonDualMaster {
		t.Fatalf("%+v", plan)
	}
	plan = planApplyHeal(1, false, reasonLiveWritableNotOracle, false, true)
	if plan.Action != actionRefuse || plan.Reason != reasonLiveWritableNotOracle {
		t.Fatalf("live extra writable must never MONITOR, got %+v", plan)
	}
}

func TestPlanApplyHeal_ZeroWritableRefuses(t *testing.T) {
	plan := planApplyHeal(0, true, "advertised_down_or_unreachable_failover_ok", true, true)
	if plan.Action != actionRefuse || plan.Reason != reasonNoWritable {
		t.Fatalf("%+v", plan)
	}
}

func TestPlanApplyHeal_EqualEpochStillEscalatesUnknownSkip(t *testing.T) {
	plan := planApplyHeal(1, false, "failover_may_promote_non_oracle", true, true)
	if plan.Action != actionRefuse || plan.Reason != reasonEqualEpochEscalate {
		t.Fatalf("%+v", plan)
	}
	plan = planApplyHeal(1, false, "failover_may_promote_non_oracle", true, false)
	if plan.Action != actionMonitor {
		t.Fatalf("escalate=false still allows MONITOR, got %+v", plan)
	}
}

func TestPlanApplyHeal_UnreachableAdsMonitorsNotFailover(t *testing.T) {
	plan := planApplyHeal(1, false, reasonAdvertisedUnreachable, true, true)
	if plan.Action != actionMonitor || plan.Reason != reasonAdvertisedUnreachable {
		t.Fatalf("fake/down ads + unique writable must MONITOR, got %+v", plan)
	}
}

func TestPlanApplyHeal_SafeFailoverUnchanged(t *testing.T) {
	plan := planApplyHeal(1, true, "legacy_failover_ok", true, true)
	if plan.Action != actionFailover {
		t.Fatalf("%+v", plan)
	}
}

func TestSentinelMasterAuth_SeparateFromProbe(t *testing.T) {
	u, p := sentinelMasterAuth("probe", "probe-pass", "", "")
	if u != "probe" || p != "probe-pass" {
		t.Fatalf("fallback %s %s", u, p)
	}
	u, p = sentinelMasterAuth("probe", "probe-pass", "sentinel", "repl-pass")
	if u != "sentinel" || p != "repl-pass" {
		t.Fatalf("override %s %s", u, p)
	}
	u, p = sentinelMasterAuth("probe", "probe-pass", "", "only-pass")
	if u != "" || p != "only-pass" {
		t.Fatalf("password-only override must not keep probe user, got %s %s", u, p)
	}
}

type fakeSentinel struct {
	addr            string
	adHost          string
	adPort          int
	failover        int
	remove          int
	monitor         int
	reset           int
	sets            [][2]string
	monIP           string
	monPort         int
	monHosts        []string
	stickAds        bool
	rejectHostnames bool
	failMonitor     bool
	failRemove      bool
}

func (f *fakeSentinel) Addr() string { return f.addr }
func (f *fakeSentinel) Failover(context.Context, string) error {
	f.failover++
	return nil
}
func (f *fakeSentinel) Remove(context.Context, string) error {
	f.remove++
	if f.failRemove {
		return errors.New("ERR remove failed")
	}
	return nil
}
func (f *fakeSentinel) Monitor(_ context.Context, _, ip string, port, _ int) error {
	f.monitor++
	f.monIP, f.monPort = ip, port
	f.monHosts = append(f.monHosts, net.JoinHostPort(ip, strconv.Itoa(port)))
	if f.failMonitor || (f.rejectHostnames && net.ParseIP(ip) == nil) {
		return errors.New("ERR Invalid IP address specified")
	}
	if !f.stickAds {
		f.adHost, f.adPort = ip, port
	}
	return nil
}
func (f *fakeSentinel) Reset(context.Context, string) error { f.reset++; return nil }
func (f *fakeSentinel) Set(_ context.Context, _, option, value string) error {
	f.sets = append(f.sets, [2]string{option, value})
	return nil
}
func (f *fakeSentinel) GetMasterAddrByName(context.Context, string) (string, int, error) {
	return f.adHost, f.adPort, nil
}

func TestHealAPI_ProductionStaleReplica_MonitorNotFailover(t *testing.T) {
	advertised, oracleAddr, flags, nodes := productionStaleReplicaNodes()
	c := &fakeSentinel{addr: "n1:26379", adHost: "10.0.0.1", adPort: 6379}
	r := New(Config{
		Apply:                 true,
		LocalSentinel:         true,
		EqualEpochEscalate:    true,
		MasterName:            "mymaster",
		Quorum:                2,
		RedisUsername:         "probe",
		RedisPassword:         "probe-pass",
		SentinelRedisUsername: "sentinel",
		SentinelRedisPassword: "repl-pass",
		HealCooldown:          0,
		MinReachableRedis:     -1,
	}, nil)
	r.writeProbe = func(context.Context, string) error { return nil }

	r.healAPI(context.Background(), c, advertised, oracleAddr, nodes, flags, true)

	if c.failover != 0 {
		t.Fatalf("FAILOVER calls=%d", c.failover)
	}
	if c.remove != 1 || c.monitor != 1 {
		t.Fatalf("want one REMOVE+MONITOR, remove=%d monitor=%d", c.remove, c.monitor)
	}
	if c.monIP != "10.0.0.2" || c.monPort != 6379 {
		t.Fatalf("MONITOR target %s:%d", c.monIP, c.monPort)
	}
	if c.reset != 0 {
		t.Fatal("RESET after successful MONITOR is thrash")
	}
	if got := sentinelAuthAfterMonitor("sentinel", "repl-pass"); len(got) != 2 {
		t.Fatal(got)
	}
	if len(c.sets) != 2 || c.sets[0] != [2]string{"auth-user", "sentinel"} || c.sets[1] != [2]string{"auth-pass", "repl-pass"} {
		t.Fatalf("auth rebind used probe user? %#v", c.sets)
	}
	host, port, _ := c.GetMasterAddrByName(context.Background(), "mymaster")
	if host != "10.0.0.2" || port != 6379 {
		t.Fatalf("ads after heal %s:%d", host, port)
	}

	// Second tick: ads already match oracle; tick would noop; calling healAPI
	// is the bug we must not do. sameRedisEndpoint is the gate.
	if !sameRedisEndpoint("10.0.0.2:6379", oracleAddr) {
		t.Fatal("second tick must noop")
	}
}

func TestHealAPI_FakeUnreachableAds_MonitorNotFailover(t *testing.T) {
	nodes := []oracle.NodeResult{
		{Addr: "10.0.0.2:6379", Role: "master", Writable: true, RunID: "m"},
		{Addr: "10.0.0.3:6379", Role: "slave", Writable: false, RunID: "s"},
	}
	c := &fakeSentinel{addr: "s1:26379", adHost: "10.255.255.254", adPort: 6379}
	r := New(Config{
		Apply:              true,
		LocalSentinel:      true,
		EqualEpochEscalate: true,
		MasterName:         "mymaster",
		Quorum:             2,
		HealCooldown:       0,
		MinReachableRedis:  -1,
	}, nil)
	r.writeProbe = func(context.Context, string) error { return nil }
	r.healAPI(context.Background(), c, "10.255.255.254:6379", "10.0.0.2:6379", nodes, "s_down,master", true)
	if c.failover != 0 {
		t.Fatalf("FAILOVER calls=%d (soak dual)", c.failover)
	}
	if c.remove != 1 || c.monitor != 1 || c.monIP != "10.0.0.2" {
		t.Fatalf("want MONITOR oracle, remove=%d monitor=%d ip=%s", c.remove, c.monitor, c.monIP)
	}
}

func TestHealAPI_LiveWritableNotOracle_NoMutations(t *testing.T) {
	nodes := []oracle.NodeResult{
		{Addr: "10.0.0.1:6379", Role: "master", Writable: true, RunID: "n1"},
		{Addr: "10.0.0.2:6379", Role: "master", Writable: true, RunID: "n2"},
	}
	c := &fakeSentinel{addr: "n1:26379", adHost: "10.0.0.1", adPort: 6379}
	r := New(Config{Apply: true, LocalSentinel: true, EqualEpochEscalate: true, MasterName: "mymaster", MinReachableRedis: -1}, nil)
	r.writeProbe = func(context.Context, string) error { return nil }
	r.healAPI(context.Background(), c, "10.0.0.1:6379", "10.0.0.2:6379", nodes, "master", true)
	if c.failover+c.remove+c.monitor+c.reset != 0 {
		t.Fatalf("must not FAILOVER or MONITOR: %+v", c)
	}
}

func healCounter(r *Reconciler, name string) int64 {
	r.metrics.mu.Lock()
	defer r.metrics.mu.Unlock()
	return r.metrics.counters[counterKey(name)]
}

func testHealReconciler(addrs []string) *Reconciler {
	r := New(Config{
		Apply:              true,
		LocalSentinel:      true,
		EqualEpochEscalate: true,
		MasterName:         "mymaster",
		Quorum:             2,
		HealCooldown:       0,
		MinReachableRedis:  -1,
		RedisAddrs:         addrs,
	}, nil)
	r.writeProbe = func(context.Context, string) error { return nil }
	return r
}

func TestHealAPI_SameRunID_AdvertisedIP_MonitorsFQDNNoFailover(t *testing.T) {
	fqdn := "n0.redis.invalid:6379"
	ip := "10.42.1.5:6379"
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
			t.Fatalf("count=%d", count)
		}
		c := &fakeSentinel{addr: "s:26379", adHost: "10.42.1.5", adPort: 6379, stickAds: true}
		r := testHealReconciler([]string{fqdn, "n1.redis.invalid:6379"})
		r.healAPI(context.Background(), c, ip, w.Addr, nodes, "master", true)
		if c.failover != 0 {
			t.Fatalf("writable %s: FAILOVER calls=%d", w.Addr, c.failover)
		}
		if c.reset != 0 {
			t.Fatalf("writable %s: RESET", w.Addr)
		}
		if c.remove != 1 || c.monitor != 1 {
			t.Fatalf("writable %s: remove=%d monitor=%d", w.Addr, c.remove, c.monitor)
		}
		if c.monIP != "n0.redis.invalid" || c.monPort != 6379 {
			t.Fatalf("writable %s: MONITOR %s:%d", w.Addr, c.monIP, c.monPort)
		}
		if healCounter(r, "heal_ok") != 0 || healCounter(r, "heal_fail") != 1 {
			t.Fatalf("writable %s: IP advertisement must not verify (ok=%d fail=%d)", w.Addr, healCounter(r, "heal_ok"), healCounter(r, "heal_fail"))
		}
	}
}

func TestHealAPI_DifferentNode_ExistingHealMonitorsSeedHostname(t *testing.T) {
	// localhost stands in for the seed FQDN: LookupIP is local, and the
	// address written to MONITOR must still be that hostname, not 10.0.0.2.
	const seed = "localhost:6379"
	nodes := []oracle.NodeResult{
		{Addr: "10.0.0.1:6379", Role: "slave", Writable: false, RunID: "n1"},
		{Addr: "10.0.0.2:6379", Role: "master", Writable: true, RunID: "n2"},
		{Addr: seed, Role: "master", Writable: true, RunID: "n2"},
	}
	w := &nodes[1] // map iteration can classify the pod IP first
	seeds := []string{"n1.redis.invalid:6379", seed, "n3.redis.invalid:6379"}
	mon := preferredSeedAddr(w, nodes, seeds)
	if classifyDiverge("10.0.0.1:6379", w.Addr, mon, w, nodes) != divergeMaster {
		t.Fatal("different node must stay on the master-change heal path")
	}
	c := &fakeSentinel{addr: "s:26379", adHost: "10.0.0.1", adPort: 6379}
	r := testHealReconciler(seeds)
	r.healAPI(context.Background(), c, "10.0.0.1:6379", w.Addr, nodes, "s_down,master", true)
	if c.failover != 0 {
		t.Fatalf("FAILOVER calls=%d", c.failover)
	}
	if c.monIP != "localhost" || c.monPort != 6379 {
		t.Fatalf("MONITOR %s:%d", c.monIP, c.monPort)
	}
	if healCounter(r, "heal_ok") != 1 || healCounter(r, "heal_fail") != 0 {
		t.Fatalf("ok=%d fail=%d", healCounter(r, "heal_ok"), healCounter(r, "heal_fail"))
	}
}

func TestHealAPI_TwoWritableDifferentRunID_NoMonitor(t *testing.T) {
	nodes := []oracle.NodeResult{
		{Addr: "10.0.0.1:6379", Role: "master", Writable: true, RunID: "n1"},
		{Addr: "n1.redis.invalid:6379", Role: "master", Writable: true, RunID: "n1"},
		{Addr: "10.0.0.2:6379", Role: "master", Writable: true, RunID: "n2"},
		{Addr: "n2.redis.invalid:6379", Role: "master", Writable: true, RunID: "n2"},
	}
	w, count := oracle.ClassifyWritable(nodes)
	if count != 2 || w == nil {
		t.Fatalf("IP+FQDN of one run_id must not look like two extra masters, count=%d", count)
	}
	c := &fakeSentinel{addr: "s:26379", adHost: "10.0.0.1", adPort: 6379}
	r := testHealReconciler([]string{"n1.redis.invalid:6379", "n2.redis.invalid:6379"})
	r.healAPI(context.Background(), c, "10.0.0.1:6379", w.Addr, nodes, "master", true)
	if c.failover != 0 || c.remove != 0 || c.monitor != 0 || c.reset != 0 {
		t.Fatalf("dual_master must not MONITOR: failover=%d remove=%d monitor=%d reset=%d", c.failover, c.remove, c.monitor, c.reset)
	}
}

func TestHealAPI_SeedIsIP_MonitorsIP(t *testing.T) {
	advertised, oracleAddr, flags, nodes := productionStaleReplicaNodes()
	c := &fakeSentinel{addr: "n1:26379", adHost: "10.0.0.1", adPort: 6379}
	r := testHealReconciler([]string{"10.0.0.1:6379", "10.0.0.2:6379", "10.0.0.3:6379"})
	r.healAPI(context.Background(), c, advertised, oracleAddr, nodes, flags, true)
	if c.failover != 0 {
		t.Fatalf("FAILOVER calls=%d", c.failover)
	}
	if c.monIP != "10.0.0.2" || c.monPort != 6379 {
		t.Fatalf("MONITOR %s:%d", c.monIP, c.monPort)
	}
	if healCounter(r, "heal_ok") != 1 {
		t.Fatalf("heal_ok=%d fail=%d", healCounter(r, "heal_ok"), healCounter(r, "heal_fail"))
	}
}

func TestHealAPI_HostnameRejected_RestoresPreviousIP(t *testing.T) {
	fqdn := "n0.redis.invalid:6379"
	ip := "10.42.1.5:6379"
	nodes := []oracle.NodeResult{
		{Addr: ip, Role: "master", Writable: true, RunID: "n0"},
		{Addr: fqdn, Role: "master", Writable: true, RunID: "n0"},
	}
	c := &fakeSentinel{addr: "s:26379", adHost: "10.42.1.5", adPort: 6379, rejectHostnames: true}
	r := testHealReconciler([]string{fqdn})
	r.cfg.RedisUsername = "sentinel"
	r.cfg.RedisPassword = "pw"
	r.healAPI(context.Background(), c, ip, ip, nodes, "master", true)
	if c.failover != 0 || c.reset != 0 {
		t.Fatalf("failover=%d reset=%d", c.failover, c.reset)
	}
	if len(c.monHosts) != 2 || c.monHosts[0] != fqdn || c.monHosts[1] != ip {
		t.Fatalf("monitor sequence %v", c.monHosts)
	}
	if c.adHost != "10.42.1.5" || c.adPort != 6379 {
		t.Fatalf("working IP entry not restored: %s:%d", c.adHost, c.adPort)
	}
	if healCounter(r, "heal_fail") != 1 || healCounter(r, "heal_ok") != 0 {
		t.Fatalf("ok=%d fail=%d", healCounter(r, "heal_ok"), healCounter(r, "heal_fail"))
	}
	if len(c.sets) != 2 || c.sets[0] != [2]string{"auth-user", "sentinel"} || c.sets[1] != [2]string{"auth-pass", "pw"} {
		t.Fatalf("restored entry lost auth: %#v", c.sets)
	}
	if r.lastHeal.IsZero() {
		t.Fatal("restored IP entry must still count toward heal cooldown")
	}
}

func TestHealAPI_VerifyProbesSeedHostnameNotPodIP(t *testing.T) {
	fqdn := "n0.redis.invalid:6379"
	ip := "10.42.1.5:6379"
	nodes := []oracle.NodeResult{
		{Addr: ip, Role: "master", Writable: true, RunID: "n0"},
		{Addr: fqdn, Role: "master", Writable: true, RunID: "n0"},
	}
	var probed []string
	c := &fakeSentinel{addr: "s:26379", adHost: "10.42.1.5", adPort: 6379}
	r := testHealReconciler([]string{fqdn})
	r.writeProbe = func(_ context.Context, addr string) error {
		probed = append(probed, addr)
		if addr == ip {
			return errors.New("tls: certificate is valid for n0.redis.invalid, not 10.42.1.5")
		}
		return nil
	}
	// masterKey is the pod IP, the way map iteration can classify it.
	r.healAPI(context.Background(), c, ip, ip, nodes, "master", true)
	if c.failover != 0 || c.reset != 0 {
		t.Fatalf("failover=%d reset=%d", c.failover, c.reset)
	}
	if c.monIP != "n0.redis.invalid" || c.monPort != 6379 {
		t.Fatalf("MONITOR %s:%d", c.monIP, c.monPort)
	}
	if healCounter(r, "heal_ok") != 1 || healCounter(r, "heal_fail") != 0 {
		t.Fatalf("ok=%d fail=%d probed=%v", healCounter(r, "heal_ok"), healCounter(r, "heal_fail"), probed)
	}
	if len(probed) != 1 || probed[0] != fqdn {
		t.Fatalf("write probe dialed %v, want %s", probed, fqdn)
	}
}

func TestHealAPI_LocalhostIP_EqualEpoch_MonitorsHostname(t *testing.T) {
	if !sameRedisEndpoint("127.0.0.1:6379", "localhost:6379") {
		t.Fatal("precondition: localhost must resolve to 127.0.0.1")
	}
	nodes := []oracle.NodeResult{
		{Addr: "127.0.0.1:6379", Role: "master", Writable: true, RunID: "n0"},
		{Addr: "localhost:6379", Role: "master", Writable: true, RunID: "n0"},
	}
	for _, masterKey := range []string{"127.0.0.1:6379", "localhost:6379"} {
		c := &fakeSentinel{addr: "s:26379", adHost: "127.0.0.1", adPort: 6379}
		r := testHealReconciler([]string{"localhost:6379"})
		r.healAPI(context.Background(), c, "127.0.0.1:6379", masterKey, nodes, "master", true)
		if c.failover != 0 || c.reset != 0 {
			t.Fatalf("masterKey %s: failover=%d reset=%d", masterKey, c.failover, c.reset)
		}
		if c.monIP != "localhost" || c.monPort != 6379 {
			t.Fatalf("masterKey %s: MONITOR %s:%d", masterKey, c.monIP, c.monPort)
		}
		if healCounter(r, "heal_ok") != 1 || healCounter(r, "apply_refused") != 0 {
			t.Fatalf("masterKey %s: ok=%d refused=%d fail=%d", masterKey, healCounter(r, "heal_ok"), healCounter(r, "apply_refused"), healCounter(r, "heal_fail"))
		}
	}
}

func TestHealAPI_IPv6Seed_VerifyAcceptsEcho(t *testing.T) {
	oracleAddr := "[2001:db8::1]:6379"
	advertised := "[2001:db8::2]:6379"
	nodes := []oracle.NodeResult{
		{Addr: advertised, Role: "slave", Writable: false, RunID: "s"},
		{Addr: oracleAddr, Role: "master", Writable: true, RunID: "m"},
	}
	// Sentinel returns the host without brackets. Sprintf would build
	// "2001:db8::1:6379", which does not match the seed.
	c := &fakeSentinel{addr: "s:26379", adHost: "2001:db8::2", adPort: 6379}
	r := testHealReconciler([]string{advertised, oracleAddr})
	r.healAPI(context.Background(), c, advertised, oracleAddr, nodes, "s_down,master", true)
	if c.failover != 0 {
		t.Fatalf("FAILOVER calls=%d", c.failover)
	}
	if c.monIP != "2001:db8::1" || c.monPort != 6379 {
		t.Fatalf("MONITOR %s:%d", c.monIP, c.monPort)
	}
	if healCounter(r, "heal_ok") != 1 || healCounter(r, "heal_fail") != 0 {
		t.Fatalf("ok=%d fail=%d", healCounter(r, "heal_ok"), healCounter(r, "heal_fail"))
	}
}

func TestHealAPI_IPv6RejectedHostname_RestoresPrevious(t *testing.T) {
	ip := "[2001:db8::1]:6379"
	fqdn := "n0.redis.invalid:6379"
	nodes := []oracle.NodeResult{
		{Addr: ip, Role: "master", Writable: true, RunID: "n0"},
		{Addr: fqdn, Role: "master", Writable: true, RunID: "n0"},
	}
	c := &fakeSentinel{addr: "s:26379", adHost: "2001:db8::1", adPort: 6379, rejectHostnames: true}
	r := testHealReconciler([]string{fqdn})
	r.cfg.RedisPassword = "pw"
	r.healAPI(context.Background(), c, ip, ip, nodes, "master", true)
	if len(c.monHosts) != 2 || c.monHosts[0] != fqdn || c.monHosts[1] != ip {
		t.Fatalf("monitor sequence %v", c.monHosts)
	}
	if c.adHost != "2001:db8::1" || c.adPort != 6379 {
		t.Fatalf("IPv6 entry not restored: %s:%d", c.adHost, c.adPort)
	}
	if healCounter(r, "heal_fail") != 1 || healCounter(r, "heal_ok") != 0 {
		t.Fatalf("ok=%d fail=%d", healCounter(r, "heal_ok"), healCounter(r, "heal_fail"))
	}
	if len(c.sets) != 1 || c.sets[0] != [2]string{"auth-pass", "pw"} {
		t.Fatalf("restored IPv6 entry lost auth: %#v", c.sets)
	}
	if r.lastHeal.IsZero() {
		t.Fatal("cooldown must stay armed when the previous entry is back")
	}
}

func TestHealAPI_RestoreFailed_RetriesWithoutCooldown(t *testing.T) {
	fqdn := "n0.redis.invalid:6379"
	ip := "10.42.1.5:6379"
	nodes := []oracle.NodeResult{
		{Addr: ip, Role: "master", Writable: true, RunID: "n0"},
		{Addr: fqdn, Role: "master", Writable: true, RunID: "n0"},
	}
	c := &fakeSentinel{addr: "s:26379", adHost: "10.42.1.5", adPort: 6379, failMonitor: true}
	r := testHealReconciler([]string{fqdn})
	r.cfg.RedisPassword = "pw"
	r.healAPI(context.Background(), c, ip, ip, nodes, "master", true)
	if c.remove != 1 || len(c.monHosts) != 2 {
		t.Fatalf("remove=%d monitors=%v", c.remove, c.monHosts)
	}
	if len(c.sets) != 0 {
		t.Fatalf("auth rebound onto a missing master: %#v", c.sets)
	}
	if healCounter(r, "heal_fail") != 1 || healCounter(r, "heal_ok") != 0 {
		t.Fatalf("ok=%d fail=%d", healCounter(r, "heal_ok"), healCounter(r, "heal_fail"))
	}
	if !r.lastHeal.IsZero() {
		t.Fatal("failed restore must not hold heal cooldown while Sentinel has no master")
	}
}

func TestHealAPI_IPMonitorFailed_KeepsCooldown(t *testing.T) {
	advertised, oracleAddr, flags, nodes := productionStaleReplicaNodes()
	c := &fakeSentinel{addr: "n1:26379", adHost: "10.0.0.1", adPort: 6379, failMonitor: true}
	r := testHealReconciler([]string{"10.0.0.1:6379", "10.0.0.2:6379", "10.0.0.3:6379"})
	r.healAPI(context.Background(), c, advertised, oracleAddr, nodes, flags, true)
	if c.failover != 0 || len(c.monHosts) != 1 || c.monHosts[0] != oracleAddr {
		t.Fatalf("failover=%d monitors=%v", c.failover, c.monHosts)
	}
	if healCounter(r, "heal_fail") != 1 || healCounter(r, "heal_ok") != 0 {
		t.Fatalf("ok=%d fail=%d", healCounter(r, "heal_ok"), healCounter(r, "heal_fail"))
	}
	if r.lastHeal.IsZero() {
		t.Fatal("failed IP MONITOR must still honor heal cooldown")
	}
}

func TestHealAPI_RemoveFailed_KeepsCooldown(t *testing.T) {
	fqdn := "n0.redis.invalid:6379"
	ip := "10.42.1.5:6379"
	nodes := []oracle.NodeResult{
		{Addr: ip, Role: "master", Writable: true, RunID: "n0"},
		{Addr: fqdn, Role: "master", Writable: true, RunID: "n0"},
	}
	c := &fakeSentinel{addr: "s:26379", adHost: "10.42.1.5", adPort: 6379, rejectHostnames: true, failRemove: true}
	r := testHealReconciler([]string{fqdn})
	r.healAPI(context.Background(), c, ip, ip, nodes, "master", true)
	if c.remove != 1 || len(c.monHosts) != 1 || c.monHosts[0] != fqdn {
		t.Fatalf("remove=%d monitors=%v", c.remove, c.monHosts)
	}
	if healCounter(r, "heal_fail") != 1 {
		t.Fatalf("fail=%d", healCounter(r, "heal_fail"))
	}
	if r.lastHeal.IsZero() {
		t.Fatal("REMOVE failed so the old entry is still there; cooldown must hold")
	}
}
