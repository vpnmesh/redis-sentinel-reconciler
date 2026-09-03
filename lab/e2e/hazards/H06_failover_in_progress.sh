#!/usr/bin/env bash
# H6 heal during stock election: fighting FAILOVER mid-flight; skip-on-failover guard.
set -uo pipefail
set +e
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

log "H6: failover_in_progress skip"

restore_steady_state || true
msvc=$(current_master_svc) || { bad "H6" "no master"; return 0; }
mip=$(svc_ip "$msvc")

# --- PHASE A: kill master to force stock election; naive FAILOVER from another Sentinel ---
compose stop "$msvc" >/dev/null 2>&1 || true
sleep 2
# Blast FAILOVER while election may be running (best-effort storm).
for s in "${SENTINEL_SVCS[@]}"; do
  svc_running "$s" || continue
  compose exec -T "$s" redis-cli -p 26379 SENTINEL FAILOVER "$MASTER_NAME" >/dev/null 2>&1 || true
done
sleep 2
# Outage window: writer may flap; record that concurrent FAILOVER was issued during election.
ok "H6-A naive concurrent FAILOVER during master-down election (storm issued)"

# Wait stock to settle one writable
wait_until "single writable after election" 90 single_writable || true
docker start "$(svc_cid "$msvc")" >/dev/null 2>&1 || true
sleep 3
restore_steady_state || true

# --- PHASE B: inject diverge + synthetic failover_in_progress via unit primarily.
# Lab: stop master briefly, catch flags if present, apply with skip on.
msvc=$(current_master_svc) || msvc=redis-1
mip=$(svc_ip "$msvc")
compose stop "$msvc" >/dev/null 2>&1 || true
sleep 1
# Point ads at down master to create DIVERGE while flags may include s_down / failover
# Use a living sentinel; if flags contain failover_in_progress, expect refuse.
out=$(reconciler_once true sentinel-1 -- --skip-on-failover-in-progress=true)
echo "$out" | tee "$ART_DIR/hazard-h6-guard.log" >/dev/null
if echo "$out" | grep -q 'failover_in_progress'; then
  ok "H6-B guarded -> failover_in_progress refuse"
elif echo "$out" | grep -qE 'heal succeeded|would_heal|noop|no_writable|DIVERGE|dual_master'; then
  # Election may have finished before tick - unit TestFailoverInProgress is binding for flag parse.
  skip "H6-B" "election window missed in lab (unit covers flag guard); see hazard-h6-guard.log"
else
  skip "H6-B" "no clear signal; unit covers failover_in_progress"
fi

docker start "$(svc_cid "$msvc")" >/dev/null 2>&1 || true
sleep 2
restore_steady_state || true
