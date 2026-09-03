#!/usr/bin/env bash
# H1 dual writable: naive MONITOR cements split-brain ads; guarded refuse.
set -uo pipefail
set +e
# shellcheck source=../lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

log "H1: dual_master cement vs refuse"

restore_steady_state || true
msvc=$(current_master_svc) || { bad "H1" "no master"; return 0; }
mip=$(svc_ip "$msvc")
slave=""
for s in "${REDIS_SVCS[@]}"; do
  [[ "$s" != "$msvc" && "$(redis_role "$s")" == "slave" ]] && { slave=$s; break; }
done
[[ -n "$slave" ]] || { bad "H1" "no slave"; return 0; }
sip=$(svc_ip "$slave")

# --- PHASE A: inject dual, naive MONITOR all Sentinels to one writable (no demote) ---
pause_sentinels "${SENTINEL_SVCS[@]}"
compose exec -T "$slave" redis-cli REPLICAOF NO ONE >/dev/null
dual=0
for _ in $(seq 1 15); do
  [[ "$(writable_count)" -ge 2 ]] && { dual=1; break; }
  sleep 1
done
if [[ "$dual" != "1" ]]; then
  bad "H1-A" "failed to inject dual"
  start_sentinels "${SENTINEL_SVCS[@]}"
  compose exec -T "$slave" redis-cli REPLICAOF "$mip" 6379 >/dev/null || true
  return 0
fi

start_sentinels "${SENTINEL_SVCS[@]}"
sleep 1
# Naive "heal": point every Sentinel at slave-as-master, leave original M writable.
for s in "${SENTINEL_SVCS[@]}"; do
  naive_monitor "$s" "$sip" || true
done
sleep 1

wc=$(writable_count)
host=$(sentinel_master_host sentinel-1)
if [[ "$wc" -lt 2 ]]; then
  bad "H1-A" "expected dual still cemented after naive MONITOR (writable=$wc)"
  restore_steady_state || true
  return 0
fi
if [[ "$host" != "$sip" ]]; then
  bad "H1-A" "naive MONITOR did not cement ads to $sip (got $host)"
  restore_steady_state || true
  return 0
fi
ok "H1-A naive MONITOR while dual -> cemented split-brain ads (writable=$wc)"

# --- PHASE B: same dual window, reconciler must refuse ---
pause_sentinels "${SENTINEL_SVCS[@]}"
# re-ensure dual (stock may demote)
compose exec -T "$slave" redis-cli REPLICAOF NO ONE >/dev/null || true
compose exec -T "$msvc" redis-cli REPLICAOF NO ONE >/dev/null || true
sleep 1
docker start "$(svc_cid sentinel-1)" >/dev/null
sleep 1
[[ "$(writable_count)" -ge 2 ]] || {
  bad "H1-B" "lost dual before guarded apply"
  start_sentinels "${SENTINEL_SVCS[@]}"
  restore_steady_state || true
  return 0
}

out=$(reconciler_once true sentinel-1)
echo "$out" | tee "$ART_DIR/hazard-h1-guard.log" >/dev/null
if ! log_has "$out" '"reason":"dual_master"'; then
  bad "H1-B" "missing dual_master refuse; tail=$(echo "$out" | tail -5 | tr '\n' '|')"
  start_sentinels "${SENTINEL_SVCS[@]}"
  restore_steady_state || true
  return 0
fi
if log_has "$out" 'heal succeeded'; then
  bad "H1-B" "must not heal on dual_master"
  start_sentinels "${SENTINEL_SVCS[@]}"
  restore_steady_state || true
  return 0
fi
start_sentinels "${SENTINEL_SVCS[@]}"
restore_steady_state || true
ok "H1-B guarded -> dual_master refuse, no heal"
