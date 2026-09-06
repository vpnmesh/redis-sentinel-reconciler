#!/usr/bin/env bash
# T09 — unrelated Sentinel already down, then kill the current Redis master
# (its colocated Sentinel stays up). Stock failover must still elect; apply
# must not invent a second writable.
set -uo pipefail
set +e
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

log "T09 failover while one unrelated Sentinel is already down"

restore_steady_state || true
msvc=$(current_master_svc) || { bad "T09" "no master"; return 0; }
old_ip=$(svc_ip "$msvc")
mi=$(redis_svc_index "$msvc")
down=""
for s in "${SENTINEL_SVCS[@]}"; do
  idx="${s#sentinel-}"
  [[ "$idx" != "$mi" ]] || continue
  down="$idx"
  break
done
[[ -n "$down" ]] || { bad "T09" "no unrelated sentinel"; return 0; }

log "master=$msvc (node-$mi $old_ip); stop unrelated sentinel-$down first"
compose stop "sentinel-$down" >/dev/null 2>&1 || true

pre_ok() {
  local h
  h=$(sentinel_master_host "sentinel-$mi" 2>/dev/null || true)
  [[ -n "$h" && "$h" != "(nil)" ]] || return 1
  writer_set_ok || return 1
  single_writable || return 1
  return 0
}
if ! wait_until "writer still ok with sentinel-$down down" 45 pre_ok; then
  bad "T09" "cluster unhealthy after killing unrelated sentinel-$down"
  docker start "$(svc_cid "sentinel-$down")" >/dev/null 2>&1 || true
  restore_steady_state || true
  return 0
fi

log "kill Redis master redis-$mi; leave sentinel-$mi up"
compose stop "redis-$mi" >/dev/null 2>&1 || true

live=$(first_live_sentinel) || { bad "T09" "no live sentinel"; docker start "$(svc_cid "redis-$mi")" "$(svc_cid "sentinel-$down")" >/dev/null 2>&1 || true; return 0; }

failover_ok() {
  local h
  h=$(sentinel_master_host "$live" 2>/dev/null || true)
  [[ -n "$h" && "$h" != "(nil)" && "$h" != "$old_ip" ]] || return 1
  single_writable || return 1
  writer_set_ok || return 1
  return 0
}
if ! wait_until "failover with sentinel-$down still down" 90 failover_ok; then
  bad "T09" "failover failed (live=$live sentinel-$down down)"
  docker start "$(svc_cid "redis-$mi")" >/dev/null 2>&1 || true
  docker start "$(svc_cid "sentinel-$down")" >/dev/null 2>&1 || true
  restore_steady_state || true
  return 0
fi
new_host=$(sentinel_master_host "$live")
log "failover OK master=$new_host; restore redis-$mi then sentinel-$down"

docker start "$(svc_cid "redis-$mi")" >/dev/null 2>&1 || true
sleep 3
demoted() {
  svc_running "redis-$mi" || return 1
  [[ "$(redis_role "redis-$mi")" == "slave" ]] || return 1
  single_writable || return 1
  writer_set_ok || return 1
  return 0
}
if ! wait_until "old redis-$mi demoted" 120 demoted; then
  compose exec -T "redis-$mi" redis-cli REPLICAOF "$new_host" 6379 >/dev/null 2>&1 || true
  if ! wait_until "manual demote redis-$mi" 30 demoted; then
    bad "T09" "old master redis-$mi did not demote"
    docker start "$(svc_cid "sentinel-$down")" >/dev/null 2>&1 || true
    restore_steady_state || true
    return 0
  fi
fi

docker start "$(svc_cid "sentinel-$down")" >/dev/null 2>&1 || true
final_ok() {
  svc_running "sentinel-$down" || return 1
  single_writable || return 1
  writer_set_ok || return 1
  return 0
}
if ! wait_until "after sentinel-$down restore" 60 final_ok; then
  bad "T09" "not unique writable after sentinel restore (count=$(writable_count))"
  restore_steady_state || true
  return 0
fi

probe=$(first_live_sentinel) || probe=sentinel-1
out=$(reconciler_once true "$probe")
echo "$out" | tee "$ART_DIR/t09-apply-once.log" >/dev/null
if echo "$out" | grep -q '"reason":"dual_master"'; then
  if [[ "$(writable_count)" -ge 2 ]]; then
    bad "T09" "dual_master after failover+restore"
    restore_steady_state || true
    return 0
  fi
fi

ok "T09 sentinel-$down down -> kill redis-$mi -> failover; single writable"
