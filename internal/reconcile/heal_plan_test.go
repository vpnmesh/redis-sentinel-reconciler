package reconcile

import (
	"context"
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
	// Reproduce the v0.1.1 gate: equal-epoch + any unsafe FAILOVER → refuse MONITOR.
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

func TestPlanApplyHeal_SafeFailoverUnchanged(t *testing.T) {
	plan := planApplyHeal(1, true, "advertised_down_or_unreachable_failover_ok", true, true)
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
	addr     string
	adHost   string
	adPort   int
	failover int
	remove   int
	monitor  int
	reset    int
	sets     [][2]string
	monIP    string
	monPort  int
}

func (f *fakeSentinel) Addr() string { return f.addr }
func (f *fakeSentinel) Failover(context.Context, string) error {
	f.failover++
	return nil
}
func (f *fakeSentinel) Remove(context.Context, string) error { f.remove++; return nil }
func (f *fakeSentinel) Monitor(_ context.Context, _, ip string, port, _ int) error {
	f.monitor++
	f.monIP, f.monPort = ip, port
	f.adHost, f.adPort = ip, port
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

	// Second tick: ads already match oracle — tick would noop; calling healAPI
	// is the bug we must not do. sameRedisEndpoint is the gate.
	if !sameRedisEndpoint("10.0.0.2:6379", oracleAddr) {
		t.Fatal("second tick must noop")
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
