#!/usr/bin/env bash
# H2 zero writable: naive MONITOR invents unreachable master; guarded refuse.
set -uo pipefail
set +e
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

log "H2: no_writable invent vs refuse"

restore_steady_state || true

# --- PHASE A: stop all Redis, naive MONITOR to fake IP -> client write fails ---
for s in "${REDIS_SVCS[@]}"; do
  compose stop "$s" >/dev/null 2>&1 || true
done
sleep 2
naive_monitor sentinel-1 "$FAKE_MASTER_IP" || true
sleep 1
if writer_set_ok; then
  bad "H2-A" "writer unexpectedly OK after inventing fake master with no Redis"
  for s in "${REDIS_SVCS[@]}"; do docker start "$(svc_cid "$s")" >/dev/null 2>&1 || true; done
  restore_steady_state || true
  return 0
fi
host=$(sentinel_master_host sentinel-1)
[[ "$host" == "$FAKE_MASTER_IP" ]] || {
  bad "H2-A" "expected fake master ad $FAKE_MASTER_IP got $host"
  for s in "${REDIS_SVCS[@]}"; do docker start "$(svc_cid "$s")" >/dev/null 2>&1 || true; done
  restore_steady_state || true
  return 0
}
ok "H2-A naive invent MONITOR -> blackhole ads, writer FAIL"

# --- PHASE B: still no Redis, reconciler must not invent ---
out=$(reconciler_once true sentinel-1)
echo "$out" | tee "$ART_DIR/hazard-h2-guard.log" >/dev/null
if ! echo "$out" | grep -qE 'no_writable_master|no_redis_nodes_discovered'; then
  bad "H2-B" "expected no_writable refuse"
  for s in "${REDIS_SVCS[@]}"; do docker start "$(svc_cid "$s")" >/dev/null 2>&1 || true; done
  restore_steady_state || true
  return 0
fi
if log_has "$out" 'heal succeeded'; then
  bad "H2-B" "must not invent/heal"
  for s in "${REDIS_SVCS[@]}"; do docker start "$(svc_cid "$s")" >/dev/null 2>&1 || true; done
  restore_steady_state || true
  return 0
fi

for s in "${REDIS_SVCS[@]}"; do docker start "$(svc_cid "$s")" >/dev/null 2>&1 || true; done
sleep 3
restore_steady_state || true
ok "H2-B guarded -> no_writable refuse, no invent"
