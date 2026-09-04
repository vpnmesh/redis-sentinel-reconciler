#!/usr/bin/env bash
# T07 - API-only product path (5 Redis + 5 Sentinel):
# 1) stop redis-1 + sentinel-1 together
# 2) after failover + rejoin, inject wrong master on sentinel-1 via SENTINEL API (no conf edit)
# 3) confirm DIVERGE
# 4) heal with reconciler --apply (FAILOVER and/or REMOVE+MONITOR) inside lab network
set -uo pipefail
set +e
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

log "T07 combined node kill -> API lie -> reconciler --apply heal"

restore_steady_state || true

# Prefer redis-1 as initial master for this scenario.
if [[ "$(redis_role redis-1)" != "master" ]]; then
  tip=$(svc_ip redis-1)
  for s in "${REDIS_SVCS[@]}"; do
    [[ "$s" == "redis-1" ]] && continue
    compose exec -T "$s" redis-cli REPLICAOF "$tip" 6379 >/dev/null || true
  done
  compose exec -T redis-1 redis-cli REPLICAOF NO ONE >/dev/null || true
  for s in "${SENTINEL_SVCS[@]}"; do
    api_point_sentinel "$s" "$tip" || true
  done
  sleep 3
fi

[[ "$(redis_role redis-1)" == "master" ]] || { bad "T07" "could not make redis-1 master for scenario"; return 0; }
old_ip=$(svc_ip redis-1)
log "step1: stop redis-1 + sentinel-1 together (old master=$old_ip)"
compose stop redis-1 sentinel-1

failover_ok() {
  local h
  h=$(sentinel_master_host sentinel-2 2>/dev/null || true)
  [[ -n "$h" && "$h" != "(nil)" && "$h" != "$old_ip" ]] || return 1
  single_writable || return 1
  writer_set_ok || return 1
  return 0
}
if ! wait_until "failover without node1" 90 failover_ok; then
  bad "T07" "failover after combined kill failed"
  docker start "$(svc_cid redis-1)" "$(svc_cid sentinel-1)" >/dev/null 2>&1 || true
  return 0
fi
live_ip=$(sentinel_master_host sentinel-2)
log "failover OK -> master=$live_ip"

log "step1b: restart redis-1 + sentinel-1"
docker start "$(svc_cid redis-1)" >/dev/null
docker start "$(svc_cid sentinel-1)" >/dev/null
sleep 3

demote_r1() {
  [[ "$(redis_role redis-1)" == "slave" ]] && single_writable
}
if [[ "$(redis_role redis-1)" == "master" ]]; then
  if ! wait_until "sentinel demotes redis-1" 45 demote_r1; then
    compose exec -T redis-1 redis-cli REPLICAOF "$live_ip" 6379 >/dev/null || true
    wait_until "manual demote redis-1" 20 demote_r1 || true
  fi
fi
wait_until "single writable after rejoin" 60 single_writable || true

master_svc=$(current_master_svc) || master_svc=""
oracle_ip=$(svc_ip "${master_svc:-redis-2}" 2>/dev/null || echo "$live_ip")
log "step2: inject wrong master on sentinel-1 via SENTINEL API only (all peers paused)"
# Pause sentinel-2..5. Leaving 4/5 up lets Hello rewrite the lie before --once.
pause_sentinels sentinel-2 sentinel-3 sentinel-4 sentinel-5
api_lie_sentinel sentinel-1

lie_ok() {
  local h
  h=$(sentinel_master_host sentinel-1 2>/dev/null || true)
  [[ "$h" == "$FAKE_MASTER_IP" ]]
}
if ! wait_until "sentinel-1 advertises fake master" 20 lie_ok; then
  bad "T07" "API lie inject failed (host=$(sentinel_master_host sentinel-1))"
  start_sentinels sentinel-2 sentinel-3 sentinel-4 sentinel-5
  return 0
fi

log "step3: confirm problem (DIVERGE vs oracle=$oracle_ip)"
[[ "$(writable_count)" == "1" ]] || { bad "T07" "need unique writable before heal"; start_sentinels sentinel-2 sentinel-3 sentinel-4 sentinel-5; return 0; }

# One-shot via reconciler-1 (there is no Compose service named "reconciler").
dry_out=$(reconciler_once false sentinel-1)
echo "$dry_out" | tee "$ART_DIR/t07-dryrun.log" >/dev/null
if ! echo "$dry_out" | grep -qE 'DIVERGE|would_heal'; then
  bad "T07" "dry-run did not report DIVERGE/would_heal"
  start_sentinels sentinel-2 sentinel-3 sentinel-4 sentinel-5
  return 0
fi
log "confirmed DIVERGE (API lie)"

log "step4: heal with reconciler --apply --once (API only, in-network)"
heal_out=$(reconciler_once true sentinel-1)
echo "$heal_out" | tee "$ART_DIR/t07-apply.log" >/dev/null

healed() {
  local h
  h=$(sentinel_master_host sentinel-1 2>/dev/null || true)
  [[ "$h" == "$oracle_ip" ]]
}

if ! echo "$heal_out" | grep -q 'heal succeeded'; then
  if ! wait_until "sentinel-1 matches oracle after apply" 30 healed; then
    bad "T07" "apply heal failed; tail=$(echo "$heal_out" | tail -8 | tr '\n' ' | ')"
    start_sentinels sentinel-2 sentinel-3 sentinel-4 sentinel-5
    restore_steady_state || true
    return 0
  fi
fi

after=$(sentinel_master_host sentinel-1)
if [[ "$after" != "$oracle_ip" ]]; then
  wait_until "advertise==oracle" 20 healed || true
  after=$(sentinel_master_host sentinel-1)
fi
if [[ "$after" != "$oracle_ip" ]]; then
  bad "T07" "post-heal advertise $after != oracle $oracle_ip"
  start_sentinels sentinel-2 sentinel-3 sentinel-4 sentinel-5
  restore_steady_state || true
  return 0
fi
log "healed sentinel-1 -> $after"

start_sentinels sentinel-2 sentinel-3 sentinel-4 sentinel-5
sleep 3
single_writable || { bad "T07" "writable not unique after heal"; restore_steady_state || true; return 0; }

ok "T07 kill node1 -> API lie -> reconciler --apply healed sentinel-1 (no conf edit)"
