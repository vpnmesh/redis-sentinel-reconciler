#!/usr/bin/env bash
# SPEC §5-C: all 5 advertise wrong; Redis M still writable -> revive each via API heal.
set -uo pipefail
set +e
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

log "SPEC-C: all Sentinels wrong - revive"
restore_steady_state || true
oip=$(oracle_ip) || { bad "SPEC-C" "no oracle"; return 0; }

pause_sentinels "${SENTINEL_SVCS[@]}"
for s in "${SENTINEL_SVCS[@]}"; do
  docker start "$(svc_cid "$s")" >/dev/null
  api_lie_sentinel "$s"
done
sleep 2

for s in "${SENTINEL_SVCS[@]}"; do
  [[ "$(sentinel_master_host "$s")" == "$FAKE_MASTER_IP" ]] || { bad "SPEC-C" "$s not lied"; restore_steady_state || true; return 0; }
done
[[ "$(writable_count)" == "1" ]] || { bad "SPEC-C" "need unique writable Redis"; return 0; }

for s in "${SENTINEL_SVCS[@]}"; do
  out=$(reconciler_once true "$s")
  echo "$out" | tee -a "$ART_DIR/spec-c-apply.log" >/dev/null
  [[ "$(sentinel_master_host "$s")" == "$oip" ]] || { bad "SPEC-C" "$s revive failed"; restore_steady_state || true; return 0; }
done
ok "SPEC-C all-5-wrong -> each local API heal -> M"
