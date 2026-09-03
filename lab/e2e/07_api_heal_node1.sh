#!/usr/bin/env bash
# T07 - API-only product path:
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
  for s in redis-2 redis-3; do
    compose exec -T "$s" redis-cli REPLICAOF "$tip" 6379 >/dev/null || true
  done
  compose exec -T redis-1 redis-cli REPLICAOF NO ONE >/dev/null || true
  for s in sentinel-1 sentinel-2 sentinel-3; do
    compose exec -T "$s" redis-cli -p 26379 SENTINEL REMOVE "$MASTER_NAME" >/dev/null 2>&1 || true
    compose exec -T "$s" redis-cli -p 26379 SENTINEL MONITOR "$MASTER_NAME" "$tip" 6379 2 >/dev/null 2>&1 || true
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
log "step2: inject wrong master on sentinel-1 via SENTINEL API only (peers paused)"
fake_ip="10.255.255.254"
compose stop sentinel-2 sentinel-3
compose exec -T sentinel-1 redis-cli -p 26379 SENTINEL REMOVE "$MASTER_NAME" >/dev/null
compose exec -T sentinel-1 redis-cli -p 26379 SENTINEL MONITOR "$MASTER_NAME" "$fake_ip" 6379 2 >/dev/null

lie_ok() {
  local h
  h=$(sentinel_master_host sentinel-1 2>/dev/null || true)
  [[ "$h" == "$fake_ip" ]]
}
if ! wait_until "sentinel-1 advertises fake master" 20 lie_ok; then
  bad "T07" "API lie inject failed (host=$(sentinel_master_host sentinel-1))"
  docker start "$(svc_cid sentinel-2)" "$(svc_cid sentinel-3)" >/dev/null 2>&1 || true
  return 0
fi

log "step3: confirm problem (DIVERGE vs oracle=$oracle_ip)"
[[ "$(writable_count)" == "1" ]] || { bad "T07" "need unique writable before heal"; return 0; }

# Rebuild reconciler image so --once / API heal is present, then run inside lab net.
compose build reconciler >/dev/null
dry_out=$(compose run --rm --no-deps --entrypoint reconciler reconciler \
  --sentinel-addr=sentinel-1:26379 \
  --master-name="$MASTER_NAME" \
  --local-sentinel \
  --redis-addrs=redis-1:6379,redis-2:6379,redis-3:6379,redis-4:6379,redis-5:6379 \
  --once 2>&1)
echo "$dry_out" | tee "$ART_DIR/t07-dryrun.log" >/dev/null
if ! echo "$dry_out" | grep -qE 'DIVERGE|would_heal'; then
  bad "T07" "dry-run did not report DIVERGE/would_heal"
  docker start "$(svc_cid sentinel-2)" "$(svc_cid sentinel-3)" >/dev/null 2>&1 || true
  return 0
fi
log "confirmed DIVERGE (API lie)"

log "step4: heal with reconciler --apply --once (API only, in-network)"
heal_out=$(compose run --rm --no-deps --entrypoint reconciler reconciler \
  --sentinel-addr=sentinel-1:26379 \
  --master-name="$MASTER_NAME" \
  --local-sentinel \
  --redis-addrs=redis-1:6379,redis-2:6379,redis-3:6379,redis-4:6379,redis-5:6379 \
  --apply --once 2>&1)
echo "$heal_out" | tee "$ART_DIR/t07-apply.log" >/dev/null

healed() {
  local h
  h=$(sentinel_master_host sentinel-1 2>/dev/null || true)
  [[ "$h" == "$oracle_ip" ]]
}

if ! echo "$heal_out" | grep -q 'heal succeeded'; then
  if ! wait_until "sentinel-1 matches oracle after apply" 30 healed; then
    bad "T07" "apply heal failed; tail=$(echo "$heal_out" | tail -8 | tr '\n' ' | ')"
    docker start "$(svc_cid sentinel-2)" "$(svc_cid sentinel-3)" >/dev/null 2>&1 || true
    restore_steady_state || true
    return 0
  fi
fi

after=$(sentinel_master_host sentinel-1)
if [[ "$after" != "$oracle_ip" ]]; then
  # Allow brief settle then re-check
  wait_until "advertise==oracle" 20 healed || true
  after=$(sentinel_master_host sentinel-1)
fi
if [[ "$after" != "$oracle_ip" ]]; then
  bad "T07" "post-heal advertise $after != oracle $oracle_ip"
  docker start "$(svc_cid sentinel-2)" "$(svc_cid sentinel-3)" >/dev/null 2>&1 || true
  restore_steady_state || true
  return 0
fi
log "healed sentinel-1 -> $after"

docker start "$(svc_cid sentinel-2)" >/dev/null 2>&1 || true
docker start "$(svc_cid sentinel-3)" >/dev/null 2>&1 || true
sleep 3
single_writable || { bad "T07" "writable not unique after heal"; restore_steady_state || true; return 0; }

ok "T07 kill node1 -> API lie -> reconciler --apply healed sentinel-1 (no conf edit)"
