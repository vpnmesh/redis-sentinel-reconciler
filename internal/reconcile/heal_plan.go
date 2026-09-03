package reconcile

import "context"

const (
	reasonLiveNonOracle         = "advertised_is_live_non_oracle"
	reasonLiveWritableNotOracle = "advertised_is_live_writable_not_oracle"
	reasonOracleNotInTopology   = "oracle_not_in_topology"
	reasonEqualEpochEscalate    = "equal_epoch_escalate"
	reasonNoWritable            = "no_writable_master"
	reasonDualMaster            = "dual_master"
)

type healAction string

const (
	actionFailover healAction = "failover"
	actionMonitor  healAction = "monitor"
	actionRefuse   healAction = "refuse"
)

// applyHealPlan is the APPLY decision after the oracle is known.
// FAILOVER unsafe ≠ MONITOR unsafe: a stale ad of a live replica is MONITOR.
type applyHealPlan struct {
	Action healAction
	Reason string
}

// planApplyHeal is the product APPLY policy (defaults: equal_epoch_escalate=true).
//
// v0.1.1 bug: any unsafe FAILOVER under equal-epoch refused MONITOR. That blocked
// the only safe API heal for a live replica advertised as s_down,master.
func planApplyHeal(writableCount int, failoverSafe bool, failoverWhy string, equalEpochTrap, escalate bool) applyHealPlan {
	if writableCount <= 0 {
		return applyHealPlan{Action: actionRefuse, Reason: reasonNoWritable}
	}
	if writableCount >= 2 {
		return applyHealPlan{Action: actionRefuse, Reason: reasonDualMaster}
	}
	if failoverSafe {
		return applyHealPlan{Action: actionFailover, Reason: failoverWhy}
	}
	switch failoverWhy {
	case reasonLiveWritableNotOracle:
		return applyHealPlan{Action: actionRefuse, Reason: failoverWhy}
	case reasonOracleNotInTopology:
		return applyHealPlan{Action: actionRefuse, Reason: failoverWhy}
	case reasonLiveNonOracle:
		// Unique writable + ads point at a live slave. MONITOR the oracle.
		// Does not need a config-epoch bump; FAILOVER here can dual-master.
		return applyHealPlan{Action: actionMonitor, Reason: failoverWhy}
	}
	if equalEpochTrap && escalate {
		return applyHealPlan{Action: actionRefuse, Reason: reasonEqualEpochEscalate}
	}
	return applyHealPlan{Action: actionMonitor, Reason: failoverWhy}
}

// sentinelHealClient is the Sentinel API used by apply (no conf rewrite).
type sentinelHealClient interface {
	Addr() string
	Failover(ctx context.Context, name string) error
	Remove(ctx context.Context, name string) error
	Monitor(ctx context.Context, name, ip string, port, quorum int) error
	Reset(ctx context.Context, pattern string) error
	Set(ctx context.Context, name, option, value string) error
	GetMasterAddrByName(ctx context.Context, name string) (host string, port int, err error)
}

func sentinelMasterAuth(probeUser, probePass, sentinelRedisUser, sentinelRedisPass string) (user, pass string) {
	if sentinelRedisUser != "" || sentinelRedisPass != "" {
		return sentinelRedisUser, sentinelRedisPass
	}
	return probeUser, probePass
}
