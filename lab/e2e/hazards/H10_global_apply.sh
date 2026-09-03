#!/usr/bin/env bash
# H10 global reconciler without --local-sentinel -> thundering herd; require local.
set -uo pipefail
set +e
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

log "H10: global apply herd vs require local-sentinel"

restore_steady_state || true
msvc=$(current_master_svc) || { bad "H10" "no master"; return 0; }
mip=$(svc_ip "$msvc")

# --- PHASE A: naive heal ALL sentinels at once (herd) while diverge ---
for s in "${SENTINEL_SVCS[@]}"; do
  naive_monitor "$s" "$FAKE_MASTER_IP" || true
done
sleep 1
# Unconstrained: MONITOR all back to M in parallel (herd)
for s in "${SENTINEL_SVCS[@]}"; do
  naive_monitor "$s" "$mip" &
done
wait || true
sleep 1
ok "H10-A naive parallel MONITOR on all 5 Sentinels (thundering herd class)"

# Re-diverge for B
for s in "${SENTINEL_SVCS[@]}"; do
  naive_monitor "$s" "$FAKE_MASTER_IP" || true
done

# --- PHASE B1: CLI refuses --apply without --local-sentinel ---
out=$(reconciler_raw \
  --sentinel-addr=sentinel-1:26379,sentinel-2:26379,sentinel-3:26379 \
  --master-name="$MASTER_NAME" \
  --redis-addrs="$(redis_seed_addrs)" \
  --once --apply 2>&1) || true
echo "$out" | tee "$ART_DIR/hazard-h10-cli.log" >/dev/null
if echo "$out" | grep -qiE 'requires --local-sentinel|local-sentinel'; then
  ok "H10-B CLI -> --apply requires --local-sentinel"
else
  bad "H10-B" "expected local-sentinel requirement; out=$(echo "$out" | tr '\n' '|')"
fi

# --- PHASE B2: with --local-sentinel heals only first addr ---
ensure_unique_writable_redis || true
msvc=""
for s in "${REDIS_SVCS[@]}"; do
  svc_running "$s" || continue
  if [[ "$(redis_role "$s")" == "master" ]] && compose exec -T "$s" redis-cli SET "e2e:h10mip:$$" 1 EX 5 >/dev/null 2>&1; then
    msvc=$s
    break
  fi
done
mip=$(svc_ip "$msvc")
# Re-lie after role repair (B1 may have taken time; Hello may have partially healed).
naive_monitor sentinel-1 "$FAKE_MASTER_IP" || true
naive_monitor sentinel-2 "$FAKE_MASTER_IP" || true
sleep 1
out2=$(reconciler_once true sentinel-1)
echo "$out2" | tee "$ART_DIR/hazard-h10-local.log" >/dev/null
h1=$(sentinel_master_host sentinel-1)
h2=$(sentinel_master_host sentinel-2)
if [[ "$h1" != "$mip" ]]; then
  bad "H10-B2" "local s1 not healed to $mip (got $h1); log=$(echo "$out2" | tail -5 | tr '\n' '|')"
  restore_steady_state || true
  return 0
fi
if [[ "$h2" == "$mip" ]]; then
  ok "H10-B2 local heal s1->oracle (s2 may converge via Hello)"
else
  ok "H10-B2 local-only: s1 healed, s2 still stale ($h2) until its sidecar"
fi

restore_steady_state || true
