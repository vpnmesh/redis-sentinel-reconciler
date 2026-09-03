#!/usr/bin/env bash
# SPEC §5-E: dual writable -> ALERT, never apply heal.
# Pause Sentinels so stock demote cannot clear the dual window before the probe.
set -uo pipefail
set +e
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

log "SPEC-E: dual_master never heal"
restore_steady_state || true
msvc=$(current_master_svc) || { bad "SPEC-E" "no master"; return 0; }
mip=$(svc_ip "$msvc")
slave=""
for s in "${REDIS_SVCS[@]}"; do
  [[ "$s" != "$msvc" && "$(redis_role "$s")" == "slave" ]] && { slave=$s; break; }
done
[[ -n "$slave" ]] || { bad "SPEC-E" "no slave"; return 0; }

pause_sentinels "${SENTINEL_SVCS[@]}"
compose exec -T "$slave" redis-cli REPLICAOF NO ONE >/dev/null

dual=0
for _ in $(seq 1 15); do
  [[ "$(writable_count)" -ge 2 ]] && { dual=1; break; }
  sleep 1
done
[[ "$dual" == "1" ]] || {
  bad "SPEC-E" "failed to inject dual"
  start_sentinels "${SENTINEL_SVCS[@]}"
  compose exec -T "$slave" redis-cli REPLICAOF "$mip" 6379 >/dev/null || true
  return 0
}

# Start one Sentinel only so reconciler can dial --sentinel-addr (oracle still from redis-addrs).
docker start "$(svc_cid sentinel-1)" >/dev/null
sleep 1

out=$(reconciler_once true sentinel-1)
echo "$out" | tee "$ART_DIR/spec-e-apply.log" >/dev/null
echo "$out" | grep -q '"reason":"dual_master"' || {
  bad "SPEC-E" "missing dual_master ALERT; tail=$(echo "$out" | tail -6 | tr '\n' ' | ')"
  start_sentinels "${SENTINEL_SVCS[@]}"
  restore_steady_state || true
  return 0
}
echo "$out" | grep -q 'heal succeeded' && {
  bad "SPEC-E" "must not heal on dual_master"
  start_sentinels "${SENTINEL_SVCS[@]}"
  restore_steady_state || true
  return 0
}
echo "$out" | grep -qi REPLICAOF && {
  bad "SPEC-E" "must not REPLICAOF"
  start_sentinels "${SENTINEL_SVCS[@]}"
  restore_steady_state || true
  return 0
}

start_sentinels "${SENTINEL_SVCS[@]}"
restore_steady_state || true
ok "SPEC-E dual_master -> ALERT only, never heal"
