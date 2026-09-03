#!/usr/bin/env bash
# H9 equal-epoch peer fight - still best-effort; document + prefer FAILOVER when safe.
set -uo pipefail
set +e
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

log "H9: equal-epoch (residual / best-effort)"

restore_steady_state || true
msvc=$(current_master_svc) || { bad "H9" "no master"; return 0; }
mip=$(svc_ip "$msvc")

# --- PHASE A: two Sentinels MONITOR different hosts without epoch bump (peer disagreement) ---
slave=""
for s in "${REDIS_SVCS[@]}"; do
  [[ "$s" != "$msvc" && "$(redis_role "$s")" == "slave" ]] && { slave=$s; break; }
done
sip=$(svc_ip "$slave")
naive_monitor sentinel-1 "$mip" || true
naive_monitor sentinel-2 "$sip" || true
sleep 1
h1=$(sentinel_master_host sentinel-1)
h2=$(sentinel_master_host sentinel-2)
if [[ "$h1" == "$h2" ]]; then
  skip "H9-A" "sentinels converged before observe (stock Hello); equal-epoch fight residual"
else
  ok "H9-A disagreeing MONITOR ads (s1=$h1 s2=$h2) - equal-epoch / peer fight class"
fi

# --- PHASE B: local sidecar heals only local (H10 complement); epoch bump still residual ---
out=$(reconciler_once true sentinel-1)
echo "$out" | tee "$ART_DIR/hazard-h9-guard.log" >/dev/null
h1=$(sentinel_master_host sentinel-1)
if [[ "$h1" != "$mip" ]]; then
  bad "H9-B" "local ads not healed to $mip (got $h1)"
  restore_steady_state || true
  return 0
fi
# Peer sentinel-2 may still disagree until its sidecar heals - expected with 1:1 model.
skip "H9-B" "local heal OK; strong equal-epoch bump without demote M still open (HAZARD still open)"

restore_steady_state || true
