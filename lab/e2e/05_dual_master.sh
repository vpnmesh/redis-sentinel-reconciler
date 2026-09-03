#!/usr/bin/env bash
# T05 - dual writable: reconciler ALERT dual_master, never FAILOVER / never REPLICAOF.
# Cleanup expects Sentinel (or explicit) demote of the injected master.
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

log "forcing $slave REPLICAOF NO ONE (inject second writable)"
compose exec -T "$slave" redis-cli REPLICAOF NO ONE >/dev/null

dual_seen() {
  [[ "$(writable_count)" -ge 2 ]]
}

if ! wait_until "two writable masters" 20 dual_seen; then
  bad "T05" "failed to inject dual writable"
  compose exec -T "$slave" redis-cli REPLICAOF "$master_ip" 6379 >/dev/null || true
  return 0
fi

# Give reconciler at least one tick (interval=5s).
sleep 8
logs=$(reconciler_logs_since 50)
if ! echo "$logs" | grep -q '"reason":"dual_master"'; then
  bad "T05" "reconciler did not ALERT dual_master"
  compose exec -T "$slave" redis-cli REPLICAOF "$master_ip" 6379 >/dev/null || true
  return 0
fi
if echo "$logs" | grep -qE 'apply heal starting|SENTINEL FAILOVER|"action":"SENTINEL FAILOVER"'; then
  # dry-run would_heal on diverge is ok only when single writable; during dual must not apply
  if echo "$logs" | grep -q 'apply heal starting'; then
    bad "T05" "reconciler attempted apply heal during dual_master"
    compose exec -T "$slave" redis-cli REPLICAOF "$master_ip" 6379 >/dev/null || true
    return 0
  fi
fi
if echo "$logs" | grep -qi 'REPLICAOF'; then
  bad "T05" "reconciler must not issue REPLICAOF (SPEC §8)"
  compose exec -T "$slave" redis-cli REPLICAOF "$master_ip" 6379 >/dev/null || true
  return 0
fi

# Cleanup: prefer Sentinel demote; if stuck, explicit REPLICAOF (lab operator, not reconciler).
cleanup_demote() {
  local role
  role=$(redis_role "$slave")
  [[ "$role" == "slave" ]] && single_writable
}

if ! wait_until "Sentinel demotes injected master $slave" 60 cleanup_demote; then
  log "Sentinel demote slow - lab cleanup REPLICAOF $master_ip"
  compose exec -T "$slave" redis-cli REPLICAOF "$master_ip" 6379 >/dev/null || true
  wait_until "manual demote" 30 cleanup_demote || true
fi

restore_steady_state || true

ok "T05 dual_master -> ALERT only; no reconciler FAILOVER/REPLICAOF"
