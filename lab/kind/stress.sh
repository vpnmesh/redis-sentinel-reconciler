#!/usr/bin/env bash
# Kind stress against the reconciler. Short, not a soak.
# S1 MONITOR flap ×N, S2 heal-lease herd, S3 dual_master refuse ticks.
set -euo pipefail

KIND_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$KIND_DIR/lib.sh"

kind_ensure_up
kind_art kind_stress
rsr_apply
restore_ads_to_writable || true

ROUNDS="${STRESS_ROUNDS:-6}"
PASS_N=0
fail_case() {
  dump_rsr_logs "fail-$1"
  kind_fail "$1: $2 (ART=$ART)"
}
pass_case() { PASS_N=$((PASS_N + 1)); kind_log "PASS $1: $2"; }

have_dual() { [[ "$(writable_count)" -ge 2 ]]; }
have_single() { [[ "$(writable_count)" == "1" ]]; }

# --- S2 first: one sticky lie + 3 apply pods racing the lease ---
kind_log "S2 heal-lease herd (3 STS apply pods, one fake MONITOR)"
scale_rsr 0
lie_all_fake
sleep 1
ads_all_fake || fail_case S2 "fake ads did not stick"
rsr_apply
wait_until "ads healed after lease herd" 90 ads_match_writable \
  || fail_case S2 "ads not healed (ad0=$(sentinel_ad_host 0))"
dump_rsr_logs s2
[[ "$(writable_count)" == "1" ]] || fail_case S2 "writable_count=$(writable_count) after herd"
acquired=0
held=0
healed=0
for i in 0 1 2; do
  f="$ART/s2-rsr-${i}.log"
  if grep -q 'heal lease acquired' "$f"; then acquired=$((acquired + 1)); fi
  if grep -q 'heal_lease_held' "$f"; then held=$((held + 1)); fi
  if grep -q 'heal succeeded' "$f"; then healed=$((healed + 1)); fi
done
kind_log "  lease acquired=$acquired held=$held heal_succeeded=$healed"
[[ "$acquired" -ge 1 ]] || fail_case S2 "no heal lease acquired"
[[ "$held" -ge 1 ]] || fail_case S2 "no heal_lease_held (herd did not contend)"
[[ "$healed" -ge 1 ]] || fail_case S2 "no heal succeeded"
writer_set_ok || fail_case S2 "writer SET failed"
pass_case S2 "acquired=$acquired held=$held healed=$healed writable=1"

# --- S1: rapid fake MONITOR flap while apply stays on ---
kind_log "S1 MONITOR flap x$ROUNDS"
fail_round=0
for n in $(seq 1 "$ROUNDS"); do
  lie_all_fake
  if ! wait_until "S1 round $n ads on writable" 45 ads_match_writable; then
    kind_log "  round $n: ads still $(sentinel_ad_host 0)"
    fail_round=$((fail_round + 1))
    restore_ads_to_writable || true
    continue
  fi
  wc="$(writable_count)"
  if [[ "$wc" != "1" ]]; then
    kind_log "  round $n: writable_count=$wc"
    fail_round=$((fail_round + 1))
    continue
  fi
  if ! writer_set_ok; then
    kind_log "  round $n: writer SET failed"
    fail_round=$((fail_round + 1))
  fi
  kind_log "  round $n ok ads=$(sentinel_ad_host 0) writable=redis-node-$(writable_idx)"
done
dump_rsr_logs s1
[[ "$fail_round" -eq 0 ]] || fail_case S1 "$fail_round/$ROUNDS rounds failed"
pass_case S1 "flapx$ROUNDS single writable + writer OK"

# --- S3: dual writable, several ticks must refuse ---
kind_log "S3 dual_master refuse ticks"
w="$(writable_idx)" || fail_case S3 "no writable"
r="$(replica_idx)" || fail_case S3 "no replica"
restore_ads_to_writable || true
sleep 2
stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
redis_cli "$(redis_pod "$r")" REPLICAOF NO ONE >/dev/null
wait_until "S3 dual injected" 30 have_dual \
  || {
    demote_to "$w"
    fail_case S3 "failed to inject dual (count=$(writable_count))"
  }
sleep 12
dump_rsr_logs s3
since_logs="$(rsr_logs_since "$stamp")"
refused="$(echo "$since_logs" | grep -c '"reason":"dual_master"' || true)"
healed="$(echo "$since_logs" | grep -c 'heal succeeded' || true)"
kind_log "  since-inject dual_master=$refused heal_succeeded=$healed"
demote_to "$w"
sleep 2
wait_until "S3 single after demote" 40 have_single \
  || fail_case S3 "cleanup left writable_count=$(writable_count)"
restore_ads_to_writable || true
[[ "$healed" -eq 0 ]] || fail_case S3 "heal succeeded under dual ($healed)"
[[ "$refused" -ge 3 ]] || fail_case S3 "expected ≥3 dual_master ticks, got $refused"
pass_case S3 "dual refuse ticks=$refused healed=0"

kind_log "PASS kind stress: $PASS_N/3 cases ART=$ART"
printf 'PASS kind stress cases=%s rounds=%s art=%s\n' "$PASS_N" "$ROUNDS" "$ART"
