#!/usr/bin/env bash
# T06 - inject Sentinel advertisement diverge (MONITOR unreachable IP while
# peers paused). Long-running sidecars are paused so the one-shot --apply
# tick is the healer. Expect heal succeeded and ads back on the writable Redis.
set -uo pipefail
set +e
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

log "T06 diverge inject on sentinel-1 -> --apply heal"

master_svc=$(current_master_svc) || { bad "T06" "no master"; return 0; }
master_ip=$(svc_ip "$master_svc")
log "oracle master=$master_svc ($master_ip); lying sentinel-1 -> $FAKE_MASTER_IP (peers + sidecars paused)"

pause_reconcilers
# Pause sentinel-2..5. Leaving 4/5 up lets Hello rewrite the lie before --once.
pause_sentinels sentinel-2 sentinel-3 sentinel-4 sentinel-5
api_lie_sentinel sentinel-1

diverged() {
  local h
  h=$(sentinel_master_host sentinel-1 2>/dev/null || true)
  [[ "$h" == "$FAKE_MASTER_IP" ]]
}

if ! wait_until "sentinel-1 advertises fake $FAKE_MASTER_IP" 20 diverged; then
  h=$(sentinel_master_host sentinel-1 || true)
  bad "T06" "lie not sticky (host=$h)"
  start_sentinels sentinel-2 sentinel-3 sentinel-4 sentinel-5
  start_reconcilers
  return 0
fi

single_writable || { bad "T06" "writable not unique during diverge"; start_sentinels sentinel-2 sentinel-3 sentinel-4 sentinel-5; start_reconcilers; return 0; }

heal_out=$(reconciler_once true sentinel-1)
echo "$heal_out" | tee "$ART_DIR/t06-apply.log" >/dev/null

healed() {
  local h
  h=$(sentinel_master_host sentinel-1 2>/dev/null || true)
  [[ "$h" == "$master_ip" ]]
}

if ! echo "$heal_out" | grep -q 'heal succeeded'; then
  if ! wait_until "sentinel-1 matches oracle after apply" 30 healed; then
    bad "T06" "apply heal failed; tail=$(echo "$heal_out" | tail -8 | tr '\n' ' | ')"
    start_sentinels sentinel-2 sentinel-3 sentinel-4 sentinel-5
    start_reconcilers
    return 0
  fi
fi

after=$(sentinel_master_host sentinel-1)
if [[ "$after" != "$master_ip" ]]; then
  wait_until "advertise==oracle" 20 healed || true
  after=$(sentinel_master_host sentinel-1)
fi
if [[ "$after" != "$master_ip" ]]; then
  bad "T06" "post-heal advertise $after != oracle $master_ip"
  start_sentinels sentinel-2 sentinel-3 sentinel-4 sentinel-5
  start_reconcilers
  return 0
fi

start_sentinels sentinel-2 sentinel-3 sentinel-4 sentinel-5
sleep 2
restore_steady_state || log "warn: restore_steady_state failed - final T01 will catch"
sleep 3
ok "T06 diverge -> --apply heal succeeded sentinel-1 -> $after"
