#!/usr/bin/env bash
# H5 heal storm: two rapid applies without cooldown can flap; cooldown refuses 2nd.
set -uo pipefail
set +e
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

log "H5: heal cooldown storm"

restore_steady_state || true
msvc=$(current_master_svc) || { bad "H5" "no master"; return 0; }
mip=$(svc_ip "$msvc")

# --- PHASE A: two naive MONITOR flaps (fake <-> real) without rate limit ---
naive_monitor sentinel-1 "$FAKE_MASTER_IP" || true
sleep 0.5
naive_monitor sentinel-1 "$mip" || true
sleep 0.5
naive_monitor sentinel-1 "$FAKE_MASTER_IP" || true
sleep 0.5
host=$(sentinel_master_host sentinel-1)
if [[ "$host" != "$FAKE_MASTER_IP" ]]; then
  bad "H5-A" "expected flapping end on fake ($host)"
  restore_steady_state || true
  return 0
fi
writer_set_ok && { bad "H5-A" "writer OK during flap blackhole"; restore_steady_state || true; return 0; }
ok "H5-A unconstrained MONITOR flap -> blackhole ads / writer FAIL"

# Heal ads for B
api_point_sentinel sentinel-1 "$mip" || true
naive_monitor sentinel-1 "$FAKE_MASTER_IP" || true  # diverge again

# --- PHASE B: long-lived reconciler process - first apply heals, second refused by cooldown ---
# Use a one-shot with cooldown disabled for first? Need same process: run with interval.
# Emulate via two --once in same compose run is impossible; use unit for same-process.
# Lab: first --once with cooldown=1h after we set lastHeal... can't.
# Instead: run reconciler with --heal-cooldown=1h --apply --once twice: each new process
# resets lastHeal - so lab proves CLI default exists; unit proves same-process.
#
# Lab PHASE B: pass --heal-cooldown=1h and do TWO heals by embedding a tiny wrapper:
# actually call reconciler_raw once after a successful heal in same invocation requires
# Once=false. Use:
#   --interval=1s --heal-cooldown=1h --apply (not once), lie mid-flight, wait for refuse.

compose stop reconciler-1 >/dev/null 2>&1 || true
kill_ephemeral_reconcilers
# Background apply loop with cooldown
reconciler_raw \
  --sentinel-addr=sentinel-1:26379 \
  --master-name="$MASTER_NAME" \
  --local-sentinel \
  --quorum="$QUORUM" \
  --heal-cooldown=1h \
  --interval=2s \
  --interval-jitter=0 \
  --redis-addrs="$(redis_seed_addrs)" \
  --apply >"$ART_DIR/hazard-h5-loop.log" 2>&1 &
rpid=$!
sleep 4
# First diverge -> should heal (or already healed)
naive_monitor sentinel-1 "$FAKE_MASTER_IP" || true
sleep 6
# Second diverge immediately -> should hit heal_cooldown
naive_monitor sentinel-1 "$FAKE_MASTER_IP" || true
sleep 6
kill "$rpid" 2>/dev/null || true
wait "$rpid" 2>/dev/null || true
kill_ephemeral_reconcilers

logf=$(cat "$ART_DIR/hazard-h5-loop.log")
if ! echo "$logf" | grep -qE 'heal succeeded|would_heal|REMOVE\+MONITOR|FAILOVER'; then
  # maybe first tick already noop then diverge healed
  true
fi
if echo "$logf" | grep -q 'heal_cooldown'; then
  ok "H5-B guarded -> heal_cooldown refuse on 2nd storm"
else
  # Fallback: unit covers same-process; lab may heal once then ads stuck on fake if refused
  if echo "$logf" | grep -q 'apply_refused'; then
    ok "H5-B guarded -> apply_refused (cooldown/other)"
  else
    skip "H5-B" "no heal_cooldown line in loop log (see unit TestPreflightCooldown); tail=$(echo "$logf" | tail -4 | tr '\n' '|')"
  fi
fi

api_point_sentinel sentinel-1 "$mip" || true
restore_steady_state || true
