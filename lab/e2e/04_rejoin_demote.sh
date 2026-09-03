#!/usr/bin/env bash
# T04 - old master rejoin: Sentinel demotes via REPLICAOF (doc §9).
# Reconciler must NOT be the demote actor (doc §8 non-goal).
set -uo pipefail
set +e
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

log "T04 old-master rejoin -> Sentinel REPLICAOF demote"

# Ensure one redis is stopped (from T02) or kill current master first.
stopped=""
for svc in redis-1 redis-2 redis-3; do
  if ! svc_running "$svc"; then
    stopped="$svc"
    break
  fi
done

if [[ -z "$stopped" ]]; then
  log "no stopped redis - kill current master first"
  old_svc=$(current_master_svc) || { bad "T04" "no master"; return 0; }
  old_ip=$(svc_ip "$old_svc")
  compose stop "$old_svc"
  stopped="$old_svc"
  failover_after_kill() {
    local h
    h=$(sentinel_master_host sentinel-1 2>/dev/null || true)
    [[ -n "$h" && "$h" != "(nil)" && "$h" != "$old_ip" ]] || return 1
    single_writable || return 1
    writer_set_ok || return 1
    return 0
  }
  if ! wait_until "failover after kill" 90 failover_after_kill; then
    bad "T04" "failover before rejoin failed"
    compose start "$stopped" || true
    return 0
  fi
fi

live_master=$(current_master_svc) || { bad "T04" "no live master before rejoin"; return 0; }
live_ip=$(svc_ip "$live_master")
log "rejoining $stopped; live master=$live_master ($live_ip)"

# Ensure Sentinels agree on live master before rejoin (avoid stale conf after T03 restart).
agree() {
  local h1 h2 h3
  h1=$(sentinel_master_host sentinel-1 2>/dev/null || true)
  h2=$(sentinel_master_host sentinel-2 2>/dev/null || true)
  h3=$(sentinel_master_host sentinel-3 2>/dev/null || true)
  [[ -n "$h1" && "$h1" == "$h2" && "$h2" == "$h3" && "$h1" == "$live_ip" ]]
}
wait_until "sentinels agree on $live_ip" 30 agree || log "warn: sentinels not fully agreed before rejoin"

compose start "$stopped"
# Brief dual-master window is allowed; wait for Sentinel demote.
demoted() {
  local role
  role=$(redis_role "$stopped")
  [[ "$role" == "slave" ]] || return 1
  single_writable || return 1
  writer_set_ok || return 1
  return 0
}

if ! wait_until "$stopped demoted to replica (Sentinel REPLICAOF)" 120 demoted; then
  role=$(redis_role "$stopped" || echo "?")
  wc=$(writable_count)
  log "sentinel dump:"; compose exec -T sentinel-1 redis-cli -p 26379 SENTINEL master "$MASTER_NAME" 2>/dev/null | tr -d '\r' | paste - - | head -20 || true
  # Isolate following cases even on FAIL.
  compose exec -T "$stopped" redis-cli REPLICAOF "$live_ip" 6379 >/dev/null 2>&1 || true
  restore_steady_state || true
  bad "T04" "demote failed role=$role writable=$wc (Sentinel should send REPLICAOF)"
  return 0
fi

# Confirm reconciler did not claim REPLICAOF heal.
logs=$(reconciler_logs_since 100)
if echo "$logs" | grep -qi 'REPLICAOF'; then
  bad "T04" "reconciler mentioned REPLICAOF (must remain Sentinel-only per SPEC §8)"
  return 0
fi

ok "T04 rejoin $stopped -> role:slave (Sentinel REPLICAOF demote), single writable"
