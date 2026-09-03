#!/usr/bin/env bash
# T06 - inject Sentinel advertisement diverge (monitor unreachable IP while peers stopped),
# expect dry-run DIVERGE/would_heal. Optional APPLY_HEAL=1 for FAILOVER attempt.
set -uo pipefail
set +e
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

log "T06 diverge inject on sentinel-1"

master_svc=$(current_master_svc) || { bad "T06" "no master"; return 0; }
master_ip=$(svc_ip "$master_svc")
fake_ip="10.255.255.254"
log "oracle master=$master_svc ($master_ip); lying sentinel-1 -> $fake_ip (peers stopped so Hello cannot correct)"

# Pause peer Hello so local lie sticks long enough for a reconciler tick.
compose stop sentinel-2 sentinel-3

compose exec -T sentinel-1 redis-cli -p 26379 SENTINEL REMOVE "$MASTER_NAME" >/dev/null
compose exec -T sentinel-1 redis-cli -p 26379 SENTINEL MONITOR "$MASTER_NAME" "$fake_ip" 6379 2 >/dev/null

diverged() {
  local h
  h=$(sentinel_master_host sentinel-1 2>/dev/null || true)
  [[ "$h" == "$fake_ip" ]]
}

if ! wait_until "sentinel-1 advertises fake $fake_ip" 20 diverged; then
  h=$(sentinel_master_host sentinel-1 || true)
  bad "T06" "lie not sticky (host=$h)"
  compose start sentinel-2 sentinel-3 || true
  compose up -d --force-recreate sentinel-1 || true
  return 0
fi

single_writable || { bad "T06" "writable not unique during diverge"; compose start sentinel-2 sentinel-3 || true; return 0; }

compose restart reconciler-1 >/dev/null
sleep 12
logs=$(reconciler_logs_since 40)

if ! echo "$logs" | grep -qE '"msg":"DIVERGE"|would_heal'; then
  bad "T06" "expected DIVERGE/would_heal; sentinel-1=$(sentinel_master_host sentinel-1) oracle=$master_ip"
  compose start sentinel-2 sentinel-3 || true
  compose up -d --force-recreate sentinel-1 || true
  return 0
fi

if [[ "${APPLY_HEAL:-0}" == "1" ]]; then
  log "APPLY_HEAL=1 - one-shot apply against published ports"
  (cd "$ROOT_DIR" && timeout 20 go run ./cmd/reconciler \
    --sentinel-addr=127.0.0.1:26379 \
    --master-name="$MASTER_NAME" \
    --local-sentinel \
    --redis-addrs=127.0.0.1:63791,127.0.0.1:63792,127.0.0.1:63793 \
    --interval=3s \
    --apply ) || true
  # FAILOVER against unreachable advertised master often fails -> fallback_needed expected.
  logs2=$(reconciler_logs_since 40)
  if echo "$logs2" | grep -qE 'heal succeeded|fallback_needed|heal failed'; then
    ok "T06 diverge would_heal + apply attempted (FAILOVER/fallback logged)"
  else
    bad "T06" "apply path produced no heal/fallback log"
  fi
else
  ok "T06 diverge -> dry-run DIVERGE/would_heal (APPLY_HEAL=1 for FAILOVER)"
fi

# Restore: start peers, then lab helper aligns Redis + Sentinel to oracle (not product path).
docker start "$(svc_cid sentinel-2)" >/dev/null 2>&1 || true
docker start "$(svc_cid sentinel-3)" >/dev/null 2>&1 || true
sleep 2
restore_steady_state || log "warn: restore_steady_state failed - final T01 will catch"
# Give Sentinel Hello a moment after MONITOR rewrite.
sleep 3
compose restart reconciler-1 >/dev/null 2>&1 || true
sleep 2