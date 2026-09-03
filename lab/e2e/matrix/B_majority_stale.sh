#!/usr/bin/env bash
# SPEC §5-B: 4 stale, 1 correct; Redis = M -> heal toward Redis (not majority).
set -uo pipefail
set +e
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

log "SPEC-B: 4 stale / 1 correct - heal toward Redis"
restore_steady_state || true
oip=$(oracle_ip) || { bad "SPEC-B" "no oracle"; return 0; }

pause_sentinels "${SENTINEL_SVCS[@]}"
# All start lied except sentinel-5 kept on oracle.
for s in sentinel-1 sentinel-2 sentinel-3 sentinel-4; do
  docker start "$(svc_cid "$s")" >/dev/null
  api_lie_sentinel "$s"
done
docker start "$(svc_cid sentinel-5)" >/dev/null
api_point_sentinel sentinel-5 "$oip"
sleep 2

[[ "$(sentinel_master_host sentinel-5)" == "$oip" ]] || { bad "SPEC-B" "s5 not correct"; restore_steady_state || true; return 0; }
[[ "$(sentinel_master_host sentinel-1)" == "$FAKE_MASTER_IP" ]] || { bad "SPEC-B" "s1 not stale"; restore_steady_state || true; return 0; }

# Heal each stale toward Redis oracle (ignore 4-vs-1 Sentinel majority).
for s in sentinel-1 sentinel-2 sentinel-3 sentinel-4; do
  out=$(reconciler_once true "$s")
  echo "$out" | tee -a "$ART_DIR/spec-b-apply.log" >/dev/null
  [[ "$(sentinel_master_host "$s")" == "$oip" ]] || { bad "SPEC-B" "$s not healed to oracle"; restore_steady_state || true; return 0; }
done
ok "SPEC-B 4 stale -> heal toward Redis oracle (not majority)"
