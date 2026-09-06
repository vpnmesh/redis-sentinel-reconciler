#!/usr/bin/env bash
# T01 - steady state: single writable, Sentinel agrees with oracle,
# long-running sidecars have --apply, one-shot --apply is noop.
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

for i in 1 2 3 4 5; do
  cid=$(svc_cid "reconciler-$i" 2>/dev/null || true)
  [[ -n "$cid" ]] || { bad "$label" "reconciler-$i not running"; return 0; }
  args=$(docker inspect -f '{{join .Args " "}}' "$cid" 2>/dev/null || true)
  echo "$args" | grep -q -- '--apply' || { bad "$label" "reconciler-$i args missing --apply"; return 0; }
done

out=$(reconciler_once true sentinel-1)
echo "$out" | tee "$ART_DIR/t01-apply-once.log" >/dev/null
echo "$out" | grep -q '"msg":"noop"' || { bad "$label" "apply --once missing noop; tail=$(echo "$out" | tail -5 | tr '\n' '|')"; return 0; }
if echo "$out" | grep -q '"reason":"dual_master"'; then
  bad "$label" "apply --once dual_master in steady window"
  return 0
fi
if echo "$out" | grep -q 'heal succeeded'; then
  bad "$label" "apply --once healed in steady window"
  return 0
fi

ok "$label single-writable + 5x --apply sidecar + --once noop"
