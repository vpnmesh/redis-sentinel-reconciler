#!/usr/bin/env bash
# T01 - steady state: single writable, Sentinel agrees with oracle, reconciler noop.
set -uo pipefail
set +e
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

label="${T01_LABEL:-T01 steady}"
log "$label"

converged() {
  local host svc
  host=$(sentinel_master_host sentinel-1 2>/dev/null || true)
  [[ -n "$host" && "$host" != "(nil)" ]] || return 1
  svc=$(ip_to_redis_svc "$host" 2>/dev/null || true)
  [[ -n "$svc" ]] || return 1
  [[ "$(redis_role "$svc")" == "master" ]] || return 1
  single_writable || return 1
  return 0
}

if ! wait_until "sentinel/oracle convergence" 60 converged; then
  bad "$label" "no converged sentinel master"
  return 0
fi

host=$(sentinel_master_host sentinel-1)
svc=$(ip_to_redis_svc "$host")

writer_set_ok || { bad "$label" "writer SET via sentinel-discovered master failed"; return 0; }

# Fresh reconciler window so prior chaos lines do not false-fail.
if [[ "${T01_REFRESH_LOGS:-1}" == "1" ]]; then
  compose restart reconciler-1 >/dev/null 2>&1 \
    || compose restart reconciler >/dev/null 2>&1 \
    || true  # Wait until a clean noop tick (ignore startup race).
  clean_noop() {
    local logs
    logs=$(reconciler_logs_since 15)
    echo "$logs" | grep -q '"msg":"noop"' || return 1
    echo "$logs" | grep -qE '"reason":"dual_master"|"msg":"DIVERGE"|would_heal' && return 1
    return 0
  }
  if ! wait_until "reconciler clean noop" 40 clean_noop; then
    bad "$label" "reconciler diverge/dual noise in steady window"
    return 0
  fi
  ok "$label single-writable + reconciler noop"
  return 0
fi

logs=$(reconciler_logs_since 25)
echo "$logs" | grep -q '"msg":"noop"' || { bad "$label" "reconciler missing noop"; return 0; }
if echo "$logs" | grep -qE '"reason":"dual_master"|"msg":"DIVERGE"|would_heal'; then
  bad "$label" "reconciler diverge/dual noise in steady window"
  return 0
fi
ok "$label single-writable + reconciler noop"
