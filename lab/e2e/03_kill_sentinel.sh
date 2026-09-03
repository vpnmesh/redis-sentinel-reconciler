#!/usr/bin/env bash
# T03 - kill one Sentinel (not writer's preferred peer): quorum remains, writer OK.
set -uo pipefail
set +e
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

log "T03 kill sentinel-2 (quorum remains)"
compose stop sentinel-2

quorum_ok() {
  local h
  h=$(sentinel_master_host sentinel-1 2>/dev/null || true)
  [[ -n "$h" && "$h" != "(nil)" ]] || return 1
  writer_set_ok || return 1
  single_writable || return 1
  return 0
}

if ! wait_until "sentinel-1 still advertises + writes" 45 quorum_ok; then
  bad "T03" "cluster unhealthy after killing sentinel-2"
  docker start "$(svc_cid sentinel-2)" >/dev/null || true
  return 0
fi

# Fresh log window - prior cases may have logged dual_master historically.
compose restart reconciler-1 >/dev/null 2>&1 || true
sleep 8
logs=$(reconciler_logs_since 20)
if echo "$logs" | grep -q '"reason":"dual_master"'; then
  # Only fail if Redis actually has >=2 writables now.
  if [[ "$(writable_count)" -ge 2 ]]; then
    bad "T03" "dual_master after sentinel kill"
    docker start "$(svc_cid sentinel-2)" >/dev/null || true
    return 0
  fi
  log "warn: stale dual_master log line ignored (writable_count=$(writable_count))"
fi

# docker start - not compose start - so we do not pull depends_on redis accidentally.
cid=$(svc_cid sentinel-2)
if [[ -z "$cid" ]]; then
  bad "T03" "empty sentinel-2 container id"
  return 0
fi
docker start "$cid" >/dev/null
sentinel2_pong() {
  docker exec "$cid" redis-cli -p 26379 PING 2>/dev/null | grep -q PONG
}
if ! wait_until "sentinel-2 back" 45 sentinel2_pong; then
  bad "T03" "sentinel-2 did not come back"
  return 0
fi

ok "T03 kill sentinel-2 -> quorum + writer OK; sentinel restarted"
