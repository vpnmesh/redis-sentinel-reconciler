#!/usr/bin/env bash
# SPEC §5-G: real master death, quorum ok -> stock Sentinel failover; reconciler usually noop.
set -uo pipefail
set +e
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

log "SPEC-G: stock failover on master death"
restore_steady_state || true
old=$(current_master_svc) || { bad "SPEC-G" "no master"; return 0; }
old_ip=$(svc_ip "$old")
compose stop "$old"

failover_ok() {
  local h
  h=$(sentinel_master_host sentinel-1 2>/dev/null || true)
  [[ -n "$h" && "$h" != "(nil)" && "$h" != "$old_ip" ]] || return 1
  single_writable || return 1
  writer_set_ok || return 1
}
if ! wait_until "stock failover" 90 failover_ok; then
  bad "SPEC-G" "failover failed"
  docker start "$(svc_cid "$old")" >/dev/null 2>&1 || true
  return 0
fi

out=$(reconciler_once false sentinel-1)
echo "$out" | tee "$ART_DIR/spec-g-dry.log" >/dev/null
# After failover + settle, expect noop (or brief diverge only if hostname/IP - should be noop).
if echo "$out" | grep -q '"reason":"dual_master"'; then
  bad "SPEC-G" "dual_master after failover"
  docker start "$(svc_cid "$old")" >/dev/null 2>&1 || true
  restore_steady_state || true
  return 0
fi

docker start "$(svc_cid "$old")" >/dev/null 2>&1 || true
wait_until "old demoted" 60 single_writable || true
restore_steady_state || true
ok "SPEC-G master death -> stock failover; reconciler no dual_master"
