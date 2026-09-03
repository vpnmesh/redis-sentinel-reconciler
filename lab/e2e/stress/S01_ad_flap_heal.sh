#!/usr/bin/env bash
# S1: rapid MONITOR flap (fake <-> oracle); guarded apply must restore writer without dual.
set -uo pipefail
set +e
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

rounds="${STRESS_ROUNDS:-8}"
log "S1: ad flap x$rounds + guarded heal"

restore_steady_state || true
msvc=$(current_master_svc) || { bad "S1" "no master"; return 0; }
mip=$(svc_ip "$msvc")

fail_round=0
for i in $(seq 1 "$rounds"); do
  naive_monitor sentinel-1 "$FAKE_MASTER_IP" || true
  out=$(reconciler_once true sentinel-1)
  h=$(sentinel_master_host sentinel-1)
  if [[ "$h" != "$mip" ]]; then
    log "S1 round $i: ads=$h want=$mip; log=$(echo "$out" | tail -2 | tr '\n' '|')"
    fail_round=$((fail_round + 1))
    ensure_unique_writable_redis || true
    api_point_sentinel sentinel-1 "$mip" || true
    continue
  fi
  wc=$(writable_count)
  if [[ "$wc" != "1" ]]; then
    log "S1 round $i: writable_count=$wc"
    fail_round=$((fail_round + 1))
    restore_steady_state || true
    msvc=$(current_master_svc) || true
    mip=$(svc_ip "$msvc")
    continue
  fi
  if ! writer_set_ok; then
    log "S1 round $i: writer FAIL after heal"
    fail_round=$((fail_round + 1))
  fi
done

if (( fail_round > 0 )); then
  bad "S1" "$fail_round/$rounds rounds failed"
  restore_steady_state || true
  return 0
fi
ok "S1 flapx$rounds -> heal keeps single writable + writer OK"
restore_steady_state || true
