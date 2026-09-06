#!/usr/bin/env bash
# Apply-everywhere soak: fake MONITOR flap while sidecars/one-shots use --apply.
# Default 60 minutes. Not a production dwell. Wall ~ SOAK_MINUTES.
set -euo pipefail
E2E_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib.sh
source "$E2E_DIR/lib.sh"

cd "$LAB_DIR"
MINUTES="${SOAK_MINUTES:-60}"
ROUNDS="${SOAK_ROUNDS:-0}"
WALL=0
[[ "$ROUNDS" -eq 0 ]] && WALL=1
if [[ "$WALL" -eq 1 ]]; then
  log "=== soak --apply wall-clock ${MINUTES}m ==="
else
  log "=== soak --apply flap x$ROUNDS (short GATE) ==="
fi
ensure_lab_up || { log "FATAL: lab not ready"; exit 1; }
export RSR_PAUSE_RECONCILERS=1
pause_reconcilers
restore_steady_state || true

msvc=$(current_master_svc) || { log "FATAL: no master"; exit 1; }
mip=$(svc_ip "$msvc")
fail_n=0
dual_n=0
t0=$(date +%s)

soak_round() {
  local i="$1" h wc
  naive_monitor sentinel-1 "$FAKE_MASTER_IP" || true
  out=$(reconciler_once true sentinel-1) || true
  if echo "$out" | grep -q 'SENTINEL FAILOVER'; then
    log "round $i used FAILOVER under unique writable (must MONITOR)"
    fail_n=$((fail_n + 1))
  fi
  h=$(sentinel_master_host sentinel-1)
  wc=$(writable_count)
  if [[ "$h" != "$mip" ]]; then
    log "round $i ads=$h want=$mip"
    fail_n=$((fail_n + 1))
    api_point_sentinel sentinel-1 "$mip" || true
  fi
  if [[ "$wc" != "1" ]]; then
    log "round $i writable_count=$wc"
    dual_n=$((dual_n + 1))
    fail_n=$((fail_n + 1))
    restore_steady_state || true
    pause_reconcilers
    msvc=$(current_master_svc) || true
    mip=$(svc_ip "$msvc")
  fi
  if (( i % 10 == 0 )); then
    log "progress $i/$ROUNDS fail=$fail_n elapsed=$(( $(date +%s) - t0 ))s"
  fi
}

if [[ "$WALL" -eq 1 ]]; then
  ROUNDS=0
  log "wall-clock ${MINUTES}m (~2 flaps/min)"
  while (( $(date +%s) - t0 < MINUTES * 60 )); do
    ROUNDS=$((ROUNDS + 1))
    soak_round "$ROUNDS"
    sleep 25
  done
else
  for i in $(seq 1 "$ROUNDS"); do
    soak_round "$i"
  done
fi

elapsed=$(( $(date +%s) - t0 ))
unset RSR_PAUSE_RECONCILERS
restore_steady_state || true
{
  echo "soak apply-everywhere"
  echo "time_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "rounds=$ROUNDS minutes_budget=$MINUTES elapsed_s=$elapsed"
  echo "fail_rounds=$fail_n dual_rounds=$dual_n"
} | tee "$ART_DIR/SOAK-$(date -u +%Y%m%dT%H%M%SZ).txt"

if (( fail_n > 0 )); then
  log "FAIL soak fail_rounds=$fail_n/$ROUNDS"
  exit 1
fi
log "PASS soak rounds=$ROUNDS elapsed=${elapsed}s single-writable"
exit 0
