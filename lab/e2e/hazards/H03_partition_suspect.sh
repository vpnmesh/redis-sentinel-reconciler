#!/usr/bin/env bash
# H3 partition / false oracle: few reachable seeds -> cement risk; min-reachable refuse.
set -uo pipefail
set +e
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

log "H3: partition_suspect vs min-reachable refuse"

restore_steady_state || true
msvc=$(current_master_svc) || { bad "H3" "no master"; return 0; }
mip=$(svc_ip "$msvc")
net=$(lab_net_name)

# Build island: sentinel-1 + master only (disconnect other redis from net).
others=()
for s in "${REDIS_SVCS[@]}"; do
  [[ "$s" != "$msvc" ]] && others+=("$s")
done

log "H3-A: isolate majority redis; naive MONITOR stays on island M while peers dark"
for s in "${others[@]}"; do
  docker network disconnect "$net" "$(svc_cid "$s")" 2>/dev/null || true
done
# Keep sentinels 2-5 with dark redis? disconnect other sentinels too so only s1+M island.
for s in sentinel-2 sentinel-3 sentinel-4 sentinel-5; do
  docker network disconnect "$net" "$(svc_cid "$s")" 2>/dev/null || true
done
sleep 2

# On island: only M reachable. Naive "heal" MONITOR to M (already correct) does little.
# Worse naive: MONITOR to fake while island still thinks it is truth for clients on s1.
naive_monitor sentinel-1 "$FAKE_MASTER_IP" || true
sleep 1
if writer_set_ok; then
  bad "H3-A" "writer OK after island blackhole MONITOR"
  restore_steady_state || true
  return 0
fi
ok "H3-A island false MONITOR -> writer FAIL (false-oracle cement risk)"

# Keep fake ads + disconnected majority so apply would be dangerous; expect refuse.
seed_list=()
for s in "${REDIS_SVCS[@]}"; do
  tip=$(svc_ip "$s" 2>/dev/null || true)
  [[ -n "$tip" ]] && seed_list+=("${tip}:6379")
done
seed_csv=$(IFS=,; echo "${seed_list[*]}")

out=$(reconciler_raw \
  --sentinel-addr=sentinel-1:26379 \
  --master-name="$MASTER_NAME" \
  --local-sentinel \
  --quorum="$QUORUM" \
  --heal-cooldown=0 \
  --min-reachable-redis=2 \
  --redis-addrs="$seed_csv" \
  --once --apply 2>&1)
echo "$out" | tee "$ART_DIR/hazard-h3-guard.log" >/dev/null

if log_has "$out" 'heal succeeded'; then
  bad "H3-B" "must not heal under partition sparse reachability"
  restore_steady_state || true
  return 0
fi
if echo "$out" | grep -qE 'partition_suspect|no_writable_master|no_redis_nodes|apply_refused|dual_master'; then
  ok "H3-B guarded -> refuse under sparse reachability"
else
  if log_has "$out" 'noop'; then
    ok "H3-B guarded -> noop (safe; no apply)"
  else
    bad "H3-B" "expected refuse/noop; tail=$(echo "$out" | tail -6 | tr '\n' '|')"
  fi
fi

restore_steady_state || true
