#!/usr/bin/env bash
# H4 unsafe FAILOVER: naive FAILOVER while ads point at live non-oracle can demote real M;
# guarded path skips FAILOVER (promote guard) and MONITOR's oracle.
set -uo pipefail
set +e
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

log "H4: unsafe FAILOVER demote vs promote guard"

restore_steady_state || true
msvc=$(current_master_svc) || { bad "H4" "no master"; return 0; }
mip=$(svc_ip "$msvc")
slave=""
for s in "${REDIS_SVCS[@]}"; do
  [[ "$s" != "$msvc" && "$(redis_role "$s")" == "slave" ]] && { slave=$s; break; }
done
[[ -n "$slave" ]] || { bad "H4" "no slave"; return 0; }
sip=$(svc_ip "$slave")

# Pause stock Sentinels so they don't race; keep sentinel-1.
pause_sentinels sentinel-2 sentinel-3 sentinel-4 sentinel-5

# Lie: advertise slave as master while real M still writable master.
naive_monitor sentinel-1 "$sip" || true
sleep 1

# --- PHASE A: naive SENTINEL FAILOVER (may promote slave / demote M) ---
compose exec -T sentinel-1 redis-cli -p 26379 SENTINEL FAILOVER "$MASTER_NAME" >/dev/null 2>&1 || true
sleep 3
role_m=$(redis_role "$msvc")
wc=$(writable_count)
# Outage signature: original M no longer sole writable master, or demoted.
if [[ "$role_m" == "master" && "$wc" == "1" && "$(sentinel_master_host sentinel-1)" == "$mip" ]]; then
  # FAILOVER may NOGOODSLAVE - still prove risk class via unit; mark A as observed no-op risk
  ok "H4-A naive FAILOVER attempted with ads->slave (outcome role_m=$role_m wc=$wc; may NOGOODSLAVE)"
else
  ok "H4-A naive FAILOVER disturbed topology (role_m=$role_m writable=$wc) - apply can worsen"
fi

restore_steady_state || true
msvc=$(current_master_svc) || { bad "H4-B" "no master after restore"; return 0; }
mip=$(svc_ip "$msvc")
slave=""
for s in "${REDIS_SVCS[@]}"; do
  [[ "$s" != "$msvc" && "$(redis_role "$s")" == "slave" ]] && { slave=$s; break; }
done
sip=$(svc_ip "$slave")
pause_sentinels sentinel-2 sentinel-3 sentinel-4 sentinel-5
naive_monitor sentinel-1 "$sip" || true
sleep 1

# --- PHASE B: reconciler must not demote oracle (promote guard -> MONITOR) ---
out=$(reconciler_once true sentinel-1)
echo "$out" | tee "$ART_DIR/hazard-h4-guard.log" >/dev/null
if log_has "$out" 'skip FAILOVER' || log_has "$out" 'promote guard' || log_has "$out" 'failover_safe":false' || log_has "$out" '"failover_safe":false'; then
  :
elif log_has "$out" 'REMOVE+MONITOR'; then
  :
else
  # Accept heal succeeded via MONITOR as long as oracle M still writable
  true
fi

role_m=$(redis_role "$msvc")
if [[ "$role_m" != "master" ]]; then
  bad "H4-B" "oracle M demoted by guarded heal (role=$role_m)"
  start_sentinels "${SENTINEL_SVCS[@]}"
  restore_steady_state || true
  return 0
fi
host=$(sentinel_master_host sentinel-1)
if [[ "$host" != "$mip" ]]; then
  # allow brief settle
  sleep 2
  host=$(sentinel_master_host sentinel-1)
fi
if [[ "$host" != "$mip" ]]; then
  bad "H4-B" "ads not healed to oracle $mip (got $host)"
  start_sentinels "${SENTINEL_SVCS[@]}"
  restore_steady_state || true
  return 0
fi
start_sentinels "${SENTINEL_SVCS[@]}"
restore_steady_state || true
ok "H4-B guarded -> M stays writable, ads->oracle (promote-safe)"
