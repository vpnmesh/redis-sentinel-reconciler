#!/usr/bin/env bash
# SPEC §5-A: 1 of 5 Sentinels stale; 4 + Redis agree on M -> API heal stale.
set -uo pipefail
set +e
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

log "SPEC-A: one stale sentinel"
restore_steady_state || true
oip=$(oracle_ip) || { bad "SPEC-A" "no oracle"; return 0; }

pause_sentinels sentinel-2 sentinel-3 sentinel-4 sentinel-5
api_lie_sentinel sentinel-1
[[ "$(sentinel_master_host sentinel-1)" == "$FAKE_MASTER_IP" ]] || { bad "SPEC-A" "lie failed"; start_sentinels sentinel-2 sentinel-3 sentinel-4 sentinel-5; return 0; }
start_sentinels sentinel-2 sentinel-3 sentinel-4 sentinel-5
# Re-point peers to oracle (they may still be correct from before pause).
for s in sentinel-2 sentinel-3 sentinel-4 sentinel-5; do
  api_point_sentinel "$s" "$oip" || true
done
sleep 2

out=$(reconciler_once false sentinel-1)
echo "$out" | tee "$ART_DIR/spec-a-dry.log" >/dev/null
echo "$out" | grep -qE 'DIVERGE|would_heal' || { bad "SPEC-A" "no DIVERGE"; return 0; }

out=$(reconciler_once true sentinel-1)
echo "$out" | tee "$ART_DIR/spec-a-apply.log" >/dev/null
[[ "$(sentinel_master_host sentinel-1)" == "$oip" ]] || { bad "SPEC-A" "heal did not fix s1"; restore_steady_state || true; return 0; }
ok "SPEC-A 1/5 stale -> API heal local -> M"
