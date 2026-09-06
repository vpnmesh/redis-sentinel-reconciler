#!/usr/bin/env bash
# H9: disagreeing Sentinel ads (equal-epoch / Hello-ignored class).
# Apply-everywhere story: each local sidecar MONITOR's the unique writable Redis.
# Stock Hello often converges before we can sample — pause majority peers so the
# split can exist long enough for two local --apply ticks.
set -uo pipefail
set +e
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

log "H9: equal-epoch disagreeing ads → two local applies converge"

restore_steady_state || true
msvc=$(current_master_svc) || { bad "H9" "no master"; return 0; }
mip=$(svc_ip "$msvc")
slave=""
for s in "${REDIS_SVCS[@]}"; do
  [[ "$s" != "$msvc" && "$(redis_role "$s")" == "slave" ]] && { slave=$s; break; }
done
[[ -n "$slave" ]] || { bad "H9" "no slave"; return 0; }
sip=$(svc_ip "$slave")

pause_sentinels sentinel-3 sentinel-4 sentinel-5

split=0
h1="" h2=""
for _ in $(seq 1 8); do
  naive_monitor sentinel-1 "$mip" || true
  naive_monitor sentinel-2 "$sip" || true
  h1=$(sentinel_master_host sentinel-1 2>/dev/null || true)
  h2=$(sentinel_master_host sentinel-2 2>/dev/null || true)
  if [[ -n "$h1" && -n "$h2" && "$h1" != "$h2" ]]; then
    split=1
    break
  fi
done

if [[ "$split" != "1" ]]; then
  start_sentinels sentinel-3 sentinel-4 sentinel-5
  skip "H9-A" "could not hold disagreeing ads (s1=$h1 s2=$h2); Hello won the race"
  restore_steady_state || true
  return 0
fi
ok "H9-A disagreeing ads s1=$h1 s2=$h2 (peers 3–5 paused)"

# Two 1:1 applies — the deploy shape for “--apply on every Sentinel”.
out1=$(reconciler_once true sentinel-1)
out2=$(reconciler_once true sentinel-2)
printf '%s\n--- sentinel-2 ---\n%s\n' "$out1" "$out2" | tee "$ART_DIR/hazard-h9-guard.log" >/dev/null

if echo "$out1$out2" | grep -qi REPLICAOF; then
  bad "H9-B" "reconciler must not issue REPLICAOF"
  start_sentinels sentinel-3 sentinel-4 sentinel-5
  restore_steady_state || true
  return 0
fi

h1=$(sentinel_master_host sentinel-1)
h2=$(sentinel_master_host sentinel-2)
wc=$(writable_count)
start_sentinels sentinel-3 sentinel-4 sentinel-5

if [[ "$h1" != "$mip" || "$h2" != "$mip" ]]; then
  bad "H9-B" "local applies did not converge ads to oracle $mip (s1=$h1 s2=$h2)"
  restore_steady_state || true
  return 0
fi
if [[ "$wc" != "1" ]]; then
  bad "H9-B" "writable_count=$wc after two local applies"
  restore_steady_state || true
  return 0
fi

# Trap log is best-effort (peer sampling via SENTINEL sentinels). Convergence is the bind.
if echo "$out1$out2" | grep -q 'equal_epoch_trap'; then
  ok "H9-B two local applies → ads=$mip writable=1 (equal_epoch_trap observed)"
else
  ok "H9-B two local applies → ads=$mip writable=1 (trap log not sampled this tick)"
fi
restore_steady_state || true
