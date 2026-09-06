#!/usr/bin/env bash
# Kind chaos against the reconciler (not generic Redis HA).
# C1 delete one rsr pod, C2 rsr kill mid-heal, C3 advertise a live replica,
# C4 dual writable must refuse apply.
set -euo pipefail

KIND_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$KIND_DIR/lib.sh"

kind_ensure_up
kind_art kind_chaos
rsr_apply
restore_ads_to_writable || true
wait_until "steady ads on writable" 30 ads_match_writable \
  || kind_fail "cluster not steady before chaos (writable=$(writable_idx || echo none) ad0=$(sentinel_ad_host 0))"

PASS_N=0
fail_case() {
  dump_rsr_logs "fail-$1"
  kind_fail "$1: $2 (ART=$ART)"
}
pass_case() { PASS_N=$((PASS_N + 1)); kind_log "PASS $1: $2"; }

# --- C1: delete one reconciler pod in steady state (our STS, not Bitnami Redis) ---
kind_log "C1 delete rsr-1 (reconciler) while ads agree"
w="$(writable_idx)" || fail_case C1 "no writable before delete"
ad_before="$(sentinel_ad_host 0)"
kubectl -n "$NS" delete pod "${RSR_RELEASE}-1" --wait=true --timeout=120s >/dev/null
kubectl -n "$NS" wait --for=condition=ready "pod/${RSR_RELEASE}-1" --timeout=120s >/dev/null
wait_sts3 "$RSR_RELEASE"
[[ "$(writable_count)" == "1" ]] || fail_case C1 "writable_count=$(writable_count) after rsr-1 restart"
w2="$(writable_idx)" || fail_case C1 "no writable after rsr-1 restart"
[[ "$w2" == "$w" ]] || fail_case C1 "writable moved ${w} → ${w2} after reconciler-only delete"
writer_set_ok || fail_case C1 "writer SET failed"
ads_match_writable || fail_case C1 "ads drifted after rsr-1 restart (ad0=$(sentinel_ad_host 0) before=$ad_before)"
pass_case C1 "rsr-1 restarted; oracle still redis-node-$w ads=$ad_before"

# --- C3: Sentinel ads a live replica (wrong master name) ---
kind_log "C3 MONITOR live replica as master"
w="$(writable_idx)" || fail_case C3 "no writable"
r="$(replica_idx)" || fail_case C3 "no replica"
rip="$(pod_ip "$(redis_pod "$r")")"
[[ -n "$rip" ]] || fail_case C3 "no replica IP"
scale_rsr 0
for i in 0 1 2; do
  point_sentinel "$(redis_pod "$i")" "$rip"
done
sleep 1
ad0="$(sentinel_ad_host 0)"
kind_log "  ads=$ad0 want replica IP $rip (writable still redis-node-$w)"
[[ "$ad0" == "$rip" ]] || fail_case C3 "lie to replica did not stick (ad=$ad0)"
[[ "$(writable_count)" == "1" ]] || fail_case C3 "inject changed writable_count=$(writable_count)"
[[ "$(writable_idx)" == "$w" ]] || fail_case C3 "oracle moved during replica-ad lie"
rsr_apply
wait_until "ads back on writable after replica-ad lie" 60 ads_match_writable \
  || fail_case C3 "ads not on writable after apply (ad0=$(sentinel_ad_host 0))"
[[ "$(writable_count)" == "1" ]] || fail_case C3 "dual after replica-ad heal writable_count=$(writable_count)"
dump_rsr_logs c3
logs="$(rsr_logs 250)"
echo "$logs" | grep -q 'heal succeeded' || fail_case C3 "no heal succeeded after replica-ad lie"
if echo "$logs" | grep -qi REPLICAOF; then
  fail_case C3 "reconciler must not issue REPLICAOF"
fi
w3="$(writable_idx)" || fail_case C3 "no writable after replica-ad heal"
pass_case C3 "ads were replica $rip; apply MONITOR'd redis-node-$w3"

# --- C2: scale down, lie, bring apply pods up, delete them before heal can settle ---
kind_log "C2 delete rsr pods mid-heal"
scale_rsr 0
lie_all_fake
sleep 1
ads_all_fake || fail_case C2 "fake ads did not stick"
helm_rsr --no-wait --set apply=true --set healCooldown=5s
kubectl -n "$NS" wait --for=condition=ready "pod/${RSR_RELEASE}-0" --timeout=90s >/dev/null || true
kubectl -n "$NS" delete pod -l app=redis-sentinel-reconciler --wait=true --timeout=120s >/dev/null
wait_sts3 "$RSR_RELEASE"
wait_until "heal after rsr pod kill" 90 ads_match_writable \
  || fail_case C2 "ads not healed after rsr restart (ad0=$(sentinel_ad_host 0))"
[[ "$(writable_count)" == "1" ]] || fail_case C2 "writable_count=$(writable_count) after rsr kill"
dump_rsr_logs c2
rsr_logs 250 | grep -q 'heal succeeded' || fail_case C2 "no heal succeeded after rsr restart"
pass_case C2 "rsr pods killed; heal re-ran onto redis-node-$(writable_idx)"

# --- C4: two writable Redis; apply must ALERT dual_master and not heal ---
kind_log "C4 dual writable refuse"
w="$(writable_idx)" || fail_case C4 "no writable"
r="$(replica_idx)" || fail_case C4 "no replica"
mip="$(pod_ip "$(redis_pod "$w")")"
restore_ads_to_writable || true
rsr_apply
sleep 2
kind_log "  REPLICAOF NO ONE on redis-node-$r (oracle redis-node-$w $mip)"
have_dual() { [[ "$(writable_count)" -ge 2 ]]; }
have_single() { [[ "$(writable_count)" == "1" ]]; }
stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
redis_cli "$(redis_pod "$r")" REPLICAOF NO ONE >/dev/null
wait_until "dual writable injected" 30 have_dual \
  || {
    demote_to "$w"
    fail_case C4 "failed to inject dual (count=$(writable_count) roles=$(redis_role 0),$(redis_role 1),$(redis_role 2))"
  }
sleep 8
dump_rsr_logs c4
since_logs="$(rsr_logs_since "$stamp")"
if ! echo "$since_logs" | grep -q '"reason":"dual_master"'; then
  demote_to "$w"
  fail_case C4 "missing dual_master ALERT"
fi
if echo "$since_logs" | grep -q 'heal succeeded'; then
  demote_to "$w"
  fail_case C4 "heal succeeded under dual_master"
fi
if echo "$since_logs" | grep -qi REPLICAOF; then
  demote_to "$w"
  fail_case C4 "reconciler issued REPLICAOF under dual"
fi
demote_to "$w"
sleep 3
wait_until "single writable after demote" 40 have_single \
  || fail_case C4 "cleanup left writable_count=$(writable_count)"
restore_ads_to_writable || true
pass_case C4 "dual_master ALERT, no heal, no REPLICAOF"

kind_log "PASS kind chaos: $PASS_N/4 cases ART=$ART"
printf 'PASS kind chaos cases=%s art=%s\n' "$PASS_N" "$ART"
