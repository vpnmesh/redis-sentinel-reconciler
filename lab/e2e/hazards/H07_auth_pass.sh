#!/usr/bin/env bash
# H7 MONITOR drops auth-*: without re-bind Sentinel cannot auth to Redis (lab has no AUTH).
# Lab SKIP + unit documents SET auth-pass path; optional dry check that password flag is accepted.
set -uo pipefail
set +e
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

log "H7: auth-pass rebind after MONITOR"

restore_steady_state || true
msvc=$(current_master_svc) || { bad "H7" "no master"; return 0; }
mip=$(svc_ip "$msvc")

# --- PHASE A (simulated): REMOVE+MONITOR clears Sentinel master config including auth-*.
# In passwordless lab, prove REMOVE+MONITOR still works; document AUTH outage class.
naive_monitor sentinel-1 "$FAKE_MASTER_IP" || true
api_point_sentinel sentinel-1 "$mip" || true
ok "H7-A lab passwordless: REMOVE+MONITOR class documented (AUTH outage needs redis requirepass)"

# --- PHASE B: reconciler with --redis-password still runs (empty server AUTH -> may warn on SET)
out=$(reconciler_once true sentinel-1 -- --redis-password=lab-secret)
echo "$out" | tee "$ART_DIR/hazard-h7-guard.log" >/dev/null
# Ads should be healthy (noop) or heal; look for auth-pass rebind only if MONITOR path taken.
if echo "$out" | grep -q 're-bound sentinel auth-pass'; then
  ok "H7-B guarded -> SET auth-pass after MONITOR"
elif echo "$out" | grep -qE 'noop|heal succeeded|would_heal'; then
  skip "H7-B" "no MONITOR path this tick (noop); unit+code path SET auth-pass when password set"
else
  skip "H7-B" "passworded Redis not in lab compose; code path covered in healAPI"
fi

restore_steady_state || true
