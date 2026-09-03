#!/usr/bin/env bash
# T02 - kill Redis master: stock Sentinel failover, single writable, writer recovers.
set -uo pipefail
set +e
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

log "T02 kill redis master"
old_svc=$(current_master_svc) || { bad "T02" "cannot resolve current master svc"; return 0; }
old_ip=$(svc_ip "$old_svc")
log "stopping master $old_svc ($old_ip)"
compose stop "$old_svc"

failover_done() {
  local h
  h=$(sentinel_master_host sentinel-2 2>/dev/null || true)
  [[ -n "$h" && "$h" != "(nil)" && "$h" != "$old_ip" ]] || return 1
  single_writable || return 1
  writer_set_ok || return 1
  return 0
}

if ! wait_until "failover away from $old_svc" 90 failover_done; then
  bad "T02" "failover did not complete"
  compose start "$old_svc" || true
  return 0
fi

new_host=$(sentinel_master_host sentinel-2)
new_svc=$(ip_to_redis_svc "$new_host" || true)
log "new master=$new_host ($new_svc)"
ok "T02 kill master -> failover + writer OK (old=$old_svc new=$new_svc)"

# leave old master stopped for T04; if run alone, restart
if [[ "${T02_RESTART_OLD:-0}" == "1" ]]; then
  compose start "$old_svc"
  wait_until "demote old master" 60 single_writable || true
fi
