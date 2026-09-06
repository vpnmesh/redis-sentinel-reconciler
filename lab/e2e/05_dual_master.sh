#!/usr/bin/env bash
# T05 - dual writable: --apply ALERT dual_master, never FAILOVER / never REPLICAOF.
# Pause peer Sentinels so stock demote cannot clear the window before the probe.
set -uo pipefail
set +e
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

log "T05 dual_master inject"

master_svc=$(current_master_svc) || { bad "T05" "no master"; return 0; }
master_ip=$(svc_ip "$master_svc")
slave=""
for svc in redis-1 redis-2 redis-3; do
  if [[ "$svc" != "$master_svc" && "$(redis_role "$svc")" == "slave" ]]; then
    slave="$svc"
    break
  fi
done
[[ -n "$slave" ]] || { bad "T05" "no slave to promote artificially"; return 0; }

pause_reconcilers
pause_sentinels "${SENTINEL_SVCS[@]}"
log "forcing $slave REPLICAOF NO ONE (inject second writable)"
compose exec -T "$slave" redis-cli REPLICAOF NO ONE >/dev/null

dual_seen() {
  [[ "$(writable_count)" -ge 2 ]]
}

if ! wait_until "two writable masters" 20 dual_seen; then
  bad "T05" "failed to inject dual writable"
  start_sentinels "${SENTINEL_SVCS[@]}"
  compose exec -T "$slave" redis-cli REPLICAOF "$master_ip" 6379 >/dev/null || true
  start_reconcilers
  return 0
fi

docker start "$(svc_cid sentinel-1)" >/dev/null
sleep 1

out=$(reconciler_once true sentinel-1)
echo "$out" | tee "$ART_DIR/t05-apply.log" >/dev/null
if ! echo "$out" | grep -q '"reason":"dual_master"'; then
  bad "T05" "missing dual_master ALERT; tail=$(echo "$out" | tail -6 | tr '\n' ' | ')"
  start_sentinels "${SENTINEL_SVCS[@]}"
  compose exec -T "$slave" redis-cli REPLICAOF "$master_ip" 6379 >/dev/null || true
  restore_steady_state || true
  return 0
fi
if echo "$out" | grep -q 'heal succeeded'; then
  bad "T05" "reconciler attempted apply heal during dual_master"
  start_sentinels "${SENTINEL_SVCS[@]}"
  compose exec -T "$slave" redis-cli REPLICAOF "$master_ip" 6379 >/dev/null || true
  restore_steady_state || true
  return 0
fi
if echo "$out" | grep -qi REPLICAOF; then
  bad "T05" "reconciler must not issue REPLICAOF (SPEC §8)"
  start_sentinels "${SENTINEL_SVCS[@]}"
  compose exec -T "$slave" redis-cli REPLICAOF "$master_ip" 6379 >/dev/null || true
  restore_steady_state || true
  return 0
fi

start_sentinels "${SENTINEL_SVCS[@]}"
compose exec -T "$slave" redis-cli REPLICAOF "$master_ip" 6379 >/dev/null || true
restore_steady_state || true

ok "T05 dual_master -> --apply ALERT only; no FAILOVER/REPLICAOF"
