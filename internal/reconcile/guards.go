package reconcile

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/vpnmesh/redis-sentinel-reconciler/internal/oracle"
)

func (r *Reconciler) refuseApply(reason string, attrs ...any) {
	args := append([]any{"event", "apply_refused", "reason", reason}, attrs...)
	r.log.Error("ALERT", args...)
	r.metrics.Inc("apply_refused")
}

// preflightApply returns false if heal must not run (HAZARD countermeasures).
func (r *Reconciler) preflightApply(flags string, nodes []oracle.NodeResult) bool {
	if r.cfg.Apply && r.cfg.RequireLocalForApply && !r.cfg.LocalSentinel && !r.cfg.AllowGlobalApply {
		r.refuseApply("apply_requires_local_sentinel", "hint", "pass --local-sentinel or --allow-global-apply")
		return false
	}
	if r.cfg.SkipOnFailoverInProgress && failoverInProgress(flags) {
		r.refuseApply("failover_in_progress", "flags", flags)
		return false
	}
	if r.cfg.HealCooldown > 0 && !r.lastHeal.IsZero() {
		since := time.Since(r.lastHeal)
		if since < r.cfg.HealCooldown {
			r.refuseApply("heal_cooldown",
				"cooldown", r.cfg.HealCooldown.String(),
				"remaining", (r.cfg.HealCooldown - since).Round(time.Second).String(),
			)
			return false
		}
	}
	minR := r.cfg.MinReachableRedis
	// 0 = auto (>=2 when >=3 static seeds). Negative = disabled (hazard lab only).
	if minR == 0 && len(r.cfg.RedisAddrs) >= 3 {
		minR = 2
	}
	if minR > 0 {
		got := countReachableSeeds(r.cfg.RedisAddrs, nodes)
		if got < minR {
			r.refuseApply("partition_suspect_few_reachable_redis",
				"reachable", got, "min", minR, "seeds", len(r.cfg.RedisAddrs),
			)
			return false
		}
	}
	return true
}

func failoverInProgress(flags string) bool {
	f := strings.ToLower(flags)
	return strings.Contains(f, "failover_in_progress") ||
		strings.Contains(f, "force_failover_host")
}

func countReachableSeeds(seeds []string, nodes []oracle.NodeResult) int {
	if len(seeds) == 0 {
		n := 0
		for i := range nodes {
			if nodes[i].Err == nil {
				n++
			}
		}
		return n
	}
	n := 0
	for _, seed := range seeds {
		for i := range nodes {
			if nodes[i].Err != nil {
				continue
			}
			if sameRedisEndpoint(nodes[i].Addr, seed) || strings.EqualFold(nodes[i].Addr, seed) {
				n++
				break
			}
		}
	}
	return n
}

func reprobeOracleWritable(ctx context.Context, masterKey string, dial oracle.Dial) error {
	n := oracle.ProbeDial(ctx, masterKey, dial)
	if n.Err != nil {
		return fmt.Errorf("oracle re-probe: %w", n.Err)
	}
	if n.Role != "master" || !n.Writable {
		return fmt.Errorf("oracle not writable after heal (role=%s writable=%v)", n.Role, n.Writable)
	}
	return nil
}
