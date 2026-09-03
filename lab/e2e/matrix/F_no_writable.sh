#!/usr/bin/env bash
# SPEC §5-F: no writable Redis -> alert, do not invent master.
set -uo pipefail
set +e
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

log "SPEC-F: no writable master"
restore_steady_state || true

for s in "${REDIS_SVCS[@]}"; do
  compose stop "$s" >/dev/null 2>&1 || true
done
sleep 2

out=$(reconciler_once true sentinel-1)
echo "$out" | tee "$ART_DIR/spec-f-apply.log" >/dev/null
echo "$out" | grep -qE 'no_writable_master|no_redis_nodes_discovered' || {
  bad "SPEC-F" "expected no_writable / no_redis alert"
  for s in "${REDIS_SVCS[@]}"; do docker start "$(svc_cid "$s")" >/dev/null 2>&1 || true; done
  restore_steady_state || true
  return 0
}
echo "$out" | grep -q 'heal succeeded' && {
  bad "SPEC-F" "must not invent/heal without writable"
  for s in "${REDIS_SVCS[@]}"; do docker start "$(svc_cid "$s")" >/dev/null 2>&1 || true; done
  restore_steady_state || true
  return 0
}

for s in "${REDIS_SVCS[@]}"; do
  docker start "$(svc_cid "$s")" >/dev/null 2>&1 || true
done
sleep 3
restore_steady_state || true
ok "SPEC-F no writable -> ALERT, no invent"
