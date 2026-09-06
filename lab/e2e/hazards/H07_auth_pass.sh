#!/usr/bin/env bash
# H7: naive REMOVE+MONITOR drops Sentinel→Redis auth-pass; guarded apply rebinds it.
# Live requirepass on the 5+5 lab (not SKIP).
set -uo pipefail
set +e
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

log "H7: auth-pass rebind after MONITOR (live requirepass)"

restore_steady_state || true
pause_reconcilers
msvc=$(current_master_svc) || { bad "H7" "no master"; start_reconcilers; return 0; }
mip=$(svc_ip "$msvc")
LAB_PASS="rsr-h7-$$"

h7_cleanup() {
  local s
  for s in "${REDIS_SVCS[@]}"; do
    compose exec -T "$s" redis-cli -a "$LAB_PASS" --no-auth-warning CONFIG SET requirepass "" >/dev/null 2>&1 || true
    compose exec -T "$s" redis-cli CONFIG SET requirepass "" >/dev/null 2>&1 || true
    compose exec -T "$s" redis-cli -a "$LAB_PASS" --no-auth-warning CONFIG SET masterauth "" >/dev/null 2>&1 || true
    compose exec -T "$s" redis-cli CONFIG SET masterauth "" >/dev/null 2>&1 || true
  done
  for s in "${SENTINEL_SVCS[@]}"; do
    svc_running "$s" || continue
    compose exec -T "$s" redis-cli -p 26379 SENTINEL SET "$MASTER_NAME" auth-pass "" >/dev/null 2>&1 || true
  done
}

h7_cleanup
for s in "${REDIS_SVCS[@]}"; do
  compose exec -T "$s" redis-cli CONFIG SET masterauth "$LAB_PASS" >/dev/null || true
done
for s in "${REDIS_SVCS[@]}"; do
  compose exec -T "$s" redis-cli CONFIG SET requirepass "$LAB_PASS" >/dev/null || true
done
for s in "${SENTINEL_SVCS[@]}"; do
  compose exec -T "$s" redis-cli -p 26379 SENTINEL SET "$MASTER_NAME" auth-pass "$LAB_PASS" >/dev/null || true
done

nopass=$(compose exec -T redis-1 redis-cli PING 2>&1 | tr -d '\r' || true)
withpass=$(compose exec -T redis-1 redis-cli -a "$LAB_PASS" --no-auth-warning PING 2>&1 | tr -d '\r' || true)
if ! echo "$nopass" | grep -qiE 'NOAUTH|ERR' || [[ "$withpass" != "PONG" ]]; then
  bad "H7" "requirepass did not stick nopass=$nopass withpass=$withpass"
  h7_cleanup
  restore_steady_state || true
  return 0
fi
# SENTINEL master redacts auth-pass; SET OK is enough before the lie.
compose exec -T sentinel-1 redis-cli -p 26379 SENTINEL SET "$MASTER_NAME" auth-pass "$LAB_PASS" >/dev/null

# --- PHASE A: naive MONITOR drops auth-* ---
pause_sentinels sentinel-2 sentinel-3 sentinel-4 sentinel-5
naive_monitor sentinel-1 "$FAKE_MASTER_IP" || true
[[ "$(sentinel_master_host sentinel-1)" == "$FAKE_MASTER_IP" ]] || {
  bad "H7-A" "lie did not stick"
  start_sentinels "${SENTINEL_SVCS[@]}"
  h7_cleanup
  restore_steady_state || true
  return 0
}
ok "H7-A naive MONITOR while Redis requirepass on (auth-* dropped by REMOVE+MONITOR)"

# --- PHASE B: --apply rebinds auth-pass and heals ads to oracle ---
out=$(reconciler_once true sentinel-1 -- --redis-password="$LAB_PASS")
echo "$out" | tee "$ART_DIR/hazard-h7-guard.log" >/dev/null
ad=$(sentinel_master_host sentinel-1)
if ! echo "$out" | grep -q 're-bound sentinel auth-pass'; then
  bad "H7-B" "missing auth-pass rebind; tail=$(echo "$out" | tail -8 | tr '\n' '|')"
  start_sentinels "${SENTINEL_SVCS[@]}"
  h7_cleanup
  restore_steady_state || true
  return 0
fi
if [[ "$ad" != "$mip" ]]; then
  bad "H7-B" "ads $ad != oracle $mip after apply"
  start_sentinels "${SENTINEL_SVCS[@]}"
  h7_cleanup
  restore_steady_state || true
  return 0
fi
set_ok=$(compose exec -T "$msvc" redis-cli -a "$LAB_PASS" --no-auth-warning SET "e2e:h7:$$" 1 EX 5 2>&1 | tr -d '\r' || true)
if [[ "$set_ok" != "OK" ]]; then
  bad "H7-B" "writer SET failed after rebind set=$set_ok"
  start_sentinels "${SENTINEL_SVCS[@]}"
  h7_cleanup
  restore_steady_state || true
  return 0
fi
ok "H7-B guarded --apply re-bound auth-pass and healed ads -> $mip"

start_sentinels "${SENTINEL_SVCS[@]}"
h7_cleanup
restore_steady_state || true
