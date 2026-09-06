#!/usr/bin/env bash
# Kind smoke + sticky wrong Sentinel master advertisement.
# Product under test: --apply on every sidecar. Lie while STS is scaled to 0,
# then scale back and wait for ads to return to the writable Redis.
set -euo pipefail

KIND_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$KIND_DIR/lib.sh"

kind_ensure_up
kind_art kind_e2e

# Leftover clusters (KIND_SKIP_UP=1) may still be dry-run from an older values file.
rsr_apply

# --- smoke ---
ready_redis="$(kubectl -n "$NS" get "sts/${REDIS_RELEASE}-node" -o jsonpath='{.status.readyReplicas}')"
ready_rsr="$(kubectl -n "$NS" get "sts/${RSR_RELEASE}" -o jsonpath='{.status.readyReplicas}')"
[[ "$ready_redis" == "3" ]] || kind_fail "redis STS readyReplicas=$ready_redis want 3"
[[ "$ready_rsr" == "3" ]] || kind_fail "rsr STS readyReplicas=$ready_rsr want 3"

kind_log "ping $(redis_pod 0)"
out="$(redis_cli "$(redis_pod 0)" PING)"
[[ "$out" == "PONG" ]] || kind_fail "PING got $out"

kind_log "sentinel get-master-addr-by-name on all 3"
declare -a ads=()
for i in 0 1 2; do
  ad="$(sentinel_ad_host "$i")"
  [[ -n "$ad" ]] || kind_fail "empty ad on node-$i"
  ads+=("$ad")
  kind_log "  node-$i ads $ad"
done
[[ "${ads[0]}" == "${ads[1]}" && "${ads[1]}" == "${ads[2]}" ]] \
  || kind_fail "sentinels disagree: ${ads[*]}"

oracle_idx="$(writable_idx)" || kind_fail "no writable Redis"
oracle_host="$(sentinel_ad_host 0)"
kind_log "oracle writable idx=$oracle_idx ad=$oracle_host"

kind_log "reconciler logs (--apply noop on agreed ads)"
started=0
for i in 0 1 2; do
  args="$(kubectl -n "$NS" get pod "${RSR_RELEASE}-${i}" -o jsonpath='{.spec.containers[0].args}')"
  echo "$args" | grep -q -- '--apply' || kind_fail "rsr-$i args missing --apply"
  logs=""
  for _ in $(seq 1 15); do
    logs="$(kubectl -n "$NS" logs "${RSR_RELEASE}-${i}" -c reconciler --tail=50 2>/dev/null || true)"
    echo "$logs" | grep -q '"msg":"noop"' && break
    sleep 2
  done
  echo "$logs" | grep -q '"msg":"noop"' || kind_fail "rsr-$i missing noop on agreed ads"
  echo "$logs" | grep -q '"apply":true' || kind_fail "rsr-$i start line missing apply=true"
  started=$((started + 1))
done
[[ "$started" -eq 3 ]] || kind_fail "started count $started"
kind_log "PASS smoke: --apply on 3/3, ads agree on $oracle_host"

# --- lie: MONITOR an unreachable IP on every Sentinel (Hello cannot rewrite) ---
kind_log "scale rsr → 0, lie all Sentinels → $FAKE_MASTER"
scale_rsr 0
lie_all_fake
sleep 1
ads_all_fake || kind_fail "lie did not stick on all Sentinels"
for i in 0 1 2; do
  kind_log "  after lie node-$i ads $(sentinel_ad_host "$i")"
done
printf 'oracle_idx=%s oracle_host=%s fake=%s\n' "$oracle_idx" "$oracle_host" "$FAKE_MASTER" \
  | tee "$ART/lie.txt" >/dev/null

role="$(redis_role "$oracle_idx")"
[[ "$role" == "master" ]] || kind_fail "oracle idx $oracle_idx lost ROLE master during lie ($role)"

kind_log "scale rsr → 3 (--apply); wait ads back on writable"
scale_rsr 3

healed=0
for _ in $(seq 1 36); do
  healed=0
  for i in 0 1 2; do
    ad="$(sentinel_ad_host "$i")"
    [[ "$ad" != "$FAKE_MASTER" && -n "$ad" ]] || continue
    logs="$(kubectl -n "$NS" logs "${RSR_RELEASE}-${i}" -c reconciler --tail=250 2>/dev/null || true)"
    if echo "$logs" | grep -q 'heal succeeded'; then
      healed=$((healed + 1))
    fi
  done
  [[ "$healed" -eq 3 ]] && break
  sleep 2
done
dump_rsr_logs apply
for i in 0 1 2; do
  ad="$(sentinel_ad_host "$i")"
  kind_log "  after apply node-$i ads $ad"
  [[ "$ad" != "$FAKE_MASTER" ]] || kind_fail "node-$i still advertises fake $FAKE_MASTER"
done
oracle_idx2="$(writable_idx)" || kind_fail "no writable Redis after apply"
[[ "$(redis_role "$oracle_idx2")" == "master" ]] || kind_fail "writable ROLE lost after apply"
[[ "$healed" -ge 1 ]] || kind_fail "no heal succeeded log after apply. ART=$ART"
for i in 0 1 2; do
  ad="$(sentinel_ad_host "$i")"
  ad_is_writable "$ad" "$oracle_idx2" || kind_fail "node-$i ad=$ad is not writable redis-node-${oracle_idx2}"
done
kind_log "PASS apply: ads on redis-node-${oracle_idx2}, heal succeeded on $healed/3"

printf 'PASS kind e2e smoke+lie+apply oracle=redis-node-%s fake=%s art=%s\n' "$oracle_idx2" "$FAKE_MASTER" "$ART"
kind_log "PASS kind e2e: 3 redis+sentinel, 3 reconciler STS --apply, lie $FAKE_MASTER healed → redis-node-${oracle_idx2}"
