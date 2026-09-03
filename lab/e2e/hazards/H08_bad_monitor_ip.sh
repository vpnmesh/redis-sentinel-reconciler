#!/usr/bin/env bash
# H8 MONITOR wrong/unreachable IP -> client blackhole; guarded heal verifies write-probe.
# Pause peer Sentinels so stock Hello cannot undo the naive MONITOR before we observe.
set -uo pipefail
set +e
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

log "H8: bad MONITOR IP vs write-probe verify"

restore_steady_state || true
msvc=$(current_master_svc) || { bad "H8" "no master"; return 0; }
mip=$(svc_ip "$msvc")

# --- PHASE A: MONITOR unreachable IP (peers paused -> no Hello rewrite) ---
pause_sentinels sentinel-2 sentinel-3 sentinel-4 sentinel-5
naive_monitor sentinel-1 "$FAKE_MASTER_IP" || true
sleep 1
host=$(sentinel_master_host sentinel-1)
if [[ "$host" != "$FAKE_MASTER_IP" ]]; then
  bad "H8-A" "ads did not stick on fake ($host); expected $FAKE_MASTER_IP"
  start_sentinels "${SENTINEL_SVCS[@]}"
  restore_steady_state || true
  return 0
fi

# Probe write via advertised master only (not any peer Sentinel view).
write_via_ad_ok=0
for client in "${REDIS_SVCS[@]}"; do
  svc_running "$client" || continue
  if compose exec -T "$client" redis-cli -h "$FAKE_MASTER_IP" -p 6379 SET "e2e:h8:$(date +%s)" ok EX 5 >/dev/null 2>&1; then
    write_via_ad_ok=1
    break
  fi
done
if [[ "$write_via_ad_ok" == "1" ]]; then
  bad "H8-A" "SET via unreachable ad $FAKE_MASTER_IP unexpectedly OK"
  start_sentinels "${SENTINEL_SVCS[@]}"
  restore_steady_state || true
  return 0
fi
ok "H8-A naive MONITOR $FAKE_MASTER_IP -> ads stuck, write via ad FAIL (blackhole)"

# Keep fake ads; repair redis roles if prior cases left no writable master.
ensure_unique_writable_redis || {
  bad "H8-B" "no unique writable redis before guarded heal"
  start_sentinels "${SENTINEL_SVCS[@]}"
  restore_steady_state || true
  return 0
}
# Prefer redis-side master (peers paused -> Sentinel get-master-addr is the lie).
msvc=""
for s in "${REDIS_SVCS[@]}"; do
  svc_running "$s" || continue
  if [[ "$(redis_role "$s")" == "master" ]] && compose exec -T "$s" redis-cli SET "e2e:h8mip:$$" 1 EX 5 >/dev/null 2>&1; then
    msvc=$s
    break
  fi
done
[[ -n "$msvc" ]] || {
  bad "H8-B" "cannot locate writable redis master"
  start_sentinels "${SENTINEL_SVCS[@]}"
  restore_steady_state || true
  return 0
}
mip=$(svc_ip "$msvc")
# Re-assert lie (ensure_unique_writable_redis does not touch Sentinel).
naive_monitor sentinel-1 "$FAKE_MASTER_IP" || true
sleep 1

# --- PHASE B: reconciler heals to oracle + verify write-probe ---
out=$(reconciler_once true sentinel-1)
echo "$out" | tee "$ART_DIR/hazard-h8-guard.log" >/dev/null
if ! log_has "$out" 'heal succeeded'; then
  bad "H8-B" "expected heal to oracle; tail=$(echo "$out" | tail -8 | tr '\n' '|')"
  start_sentinels "${SENTINEL_SVCS[@]}"
  restore_steady_state || true
  return 0
fi
host=$(sentinel_master_host sentinel-1)
if [[ "$host" != "$mip" ]]; then
  sleep 2
  host=$(sentinel_master_host sentinel-1)
fi
if [[ "$host" != "$mip" ]]; then
  bad "H8-B" "ads not oracle $mip (got $host)"
  start_sentinels "${SENTINEL_SVCS[@]}"
  restore_steady_state || true
  return 0
fi
if ! compose exec -T "$msvc" redis-cli SET "e2e:h8:verify:$(date +%s)" ok EX 5 >/dev/null 2>&1; then
  bad "H8-B" "oracle write-probe FAIL after guarded heal"
  start_sentinels "${SENTINEL_SVCS[@]}"
  restore_steady_state || true
  return 0
fi
start_sentinels "${SENTINEL_SVCS[@]}"
restore_steady_state || true
ok "H8-B guarded heal -> ads+write-probe OK"
