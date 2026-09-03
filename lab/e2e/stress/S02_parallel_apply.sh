#!/usr/bin/env bash
# S2: parallel --apply --once storm (no lease yet) - must not create dual writable.
# Documents R10 gap: multiple heals may succeed; invariant = Redis stays single-writable.
set -uo pipefail
set +e
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

log "S2: parallel apply storm (herd class; single-writable invariant)"

restore_steady_state || true
msvc=$(current_master_svc) || { bad "S2" "no master"; return 0; }
mip=$(svc_ip "$msvc")

for s in "${SENTINEL_SVCS[@]}"; do
  naive_monitor "$s" "$FAKE_MASTER_IP" || true
done
sleep 1

# Fire 5 local applies in parallel (one per Sentinel) - cooldown 0, new processes.
pids=()
for s in "${SENTINEL_SVCS[@]}"; do
  (
    reconciler_once true "$s" >"$ART_DIR/stress-s2-$s.log" 2>&1 || true
  ) &
  pids+=($!)
done
for p in "${pids[@]}"; do
  wait "$p" || true
done
sleep 2

wc=$(writable_count)
if [[ "$wc" != "1" ]]; then
  bad "S2" "parallel apply created writable_count=$wc (must stay 1)"
  restore_steady_state || true
  return 0
fi
if ! writer_set_ok; then
  bad "S2" "writer FAIL after parallel storm"
  restore_steady_state || true
  return 0
fi
# Note residual: without lease, multiple heals may still run - R10 tracks serialization.
ok "S2 parallel applyx5 -> single writable + writer OK (lease R10 still open)"
restore_steady_state || true
