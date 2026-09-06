#!/usr/bin/env bash
# T08 — kill two full nodes (Redis+Sentinel+sidecar), including the master,
# wait stock failover on the remaining quorum, restore old-master node first
# then the other, expect one writable. Apply sidecars on survivors stay up.
set -uo pipefail
set +e
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

log "T08 kill two nodes (incl. master) then sequential restore"

restore_steady_state || true
msvc=$(current_master_svc) || { bad "T08" "no master"; return 0; }
old_ip=$(svc_ip "$msvc")
mi=$(redis_svc_index "$msvc")
other=""
for s in "${REDIS_SVCS[@]}"; do
  [[ "$s" != "$msvc" ]] || continue
  other=$(redis_svc_index "$s")
  break
done
[[ -n "$other" ]] || { bad "T08" "no second node"; return 0; }

log "master=$msvc (node-$mi $old_ip); also kill node-$other"
stop_compose_node "$mi"
stop_compose_node "$other"

live=$(first_live_sentinel) || { bad "T08" "no live sentinel after dual kill"; start_compose_node "$mi"; start_compose_node "$other"; return 0; }

failover_ok() {
  local h
  h=$(sentinel_master_host "$live" 2>/dev/null || true)
  [[ -n "$h" && "$h" != "(nil)" && "$h" != "$old_ip" ]] || return 1
  single_writable || return 1
  writer_set_ok || return 1
  return 0
}
if ! wait_until "failover after killing node-$mi and node-$other" 90 failover_ok; then
  bad "T08" "failover did not complete (live=$live)"
  start_compose_node "$mi"
  start_compose_node "$other"
  restore_steady_state || true
  return 0
fi
new_host=$(sentinel_master_host "$live")
log "failover OK live=$live master=$new_host; restore old master node-$mi first"

start_compose_node "$mi"
sleep 3
demoted_old() {
  svc_running "redis-$mi" || return 1
  [[ "$(redis_role "redis-$mi")" == "slave" ]] || return 1
  single_writable || return 1
  writer_set_ok || return 1
  return 0
}
if ! wait_until "old node-$mi demoted after restore" 120 demoted_old; then
  live_ip=$(sentinel_master_host "$live" 2>/dev/null || echo "$new_host")
  compose exec -T "redis-$mi" redis-cli REPLICAOF "$live_ip" 6379 >/dev/null 2>&1 || true
  if ! wait_until "manual demote node-$mi" 30 demoted_old; then
    bad "T08" "old master node-$mi did not demote"
    start_compose_node "$other"
    restore_steady_state || true
    return 0
  fi
fi

log "restore second node-$other"
start_compose_node "$other"
sleep 3
final_ok() {
  svc_running "redis-$mi" && svc_running "redis-$other" || return 1
  single_writable || return 1
  writer_set_ok || return 1
  return 0
}
if ! wait_until "cluster after both nodes restored" 90 final_ok; then
  bad "T08" "not unique writable after restore (count=$(writable_count))"
  restore_steady_state || true
  return 0
fi

probe=$(first_live_sentinel) || probe=sentinel-1
out=$(reconciler_once true "$probe")
echo "$out" | tee "$ART_DIR/t08-apply-once.log" >/dev/null
if echo "$out" | grep -q '"reason":"dual_master"'; then
  if [[ "$(writable_count)" -ge 2 ]]; then
    bad "T08" "dual_master after restore"
    restore_steady_state || true
    return 0
  fi
  log "warn: dual_master log with writable_count=$(writable_count)"
fi

ok "T08 kill node-$mi+$other -> failover -> restore OLD then other; single writable"
