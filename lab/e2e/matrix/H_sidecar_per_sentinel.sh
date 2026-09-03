#!/usr/bin/env bash
# SPEC §4/§6: one reconciler sidecar per Sentinel - each heals only its local Sentinel.
set -uo pipefail
set +e
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

log "SPEC-SIDECAR: 1 reconciler per Sentinel (5 sidecars)"
restore_steady_state || true
oip=$(oracle_ip) || { bad "SPEC-SIDECAR" "no oracle"; return 0; }

# 1) All sidecar containers must be running and bound to distinct local sentinels.
missing=0
for i in 1 2 3 4 5; do
  if ! svc_running "reconciler-$i"; then
    log "missing reconciler-$i - bringing stack up"
    compose up -d --build "reconciler-$i" || true
    sleep 2
  fi
  if ! svc_running "reconciler-$i"; then
    bad "SPEC-SIDECAR" "reconciler-$i not running"
    missing=1
  fi
done
[[ "$missing" == "0" ]] || return 0

# Dry-run sidecars should log noop for their local sentinel (not heal peers).
sleep 6
for i in 1 2 3 4 5; do
  logs=$(compose logs "reconciler-$i" --tail=30 2>/dev/null || true)
  if ! echo "$logs" | grep -q "sentinel-$i:26379"; then
    bad "SPEC-SIDECAR" "reconciler-$i logs lack local sentinel-$i addr"
    return 0
  fi
  # Must not claim heal of a *different* sentinel index in apply path (dry-run).
  if echo "$logs" | grep -qE 'heal succeeded.*"sentinel":"sentinel-[^'"$i"']'; then
    bad "SPEC-SIDECAR" "reconciler-$i healed non-local sentinel"
    return 0
  fi
done

# 2) Lie on all Sentinels; each sidecar --apply --once heals only its local.
pause_sentinels "${SENTINEL_SVCS[@]}"
for i in 1 2 3 4 5; do
  docker start "$(svc_cid "sentinel-$i")" >/dev/null
  api_lie_sentinel "sentinel-$i"
done
sleep 2

for i in 1 2 3 4 5; do
  [[ "$(sentinel_master_host "sentinel-$i")" == "$FAKE_MASTER_IP" ]] || {
    bad "SPEC-SIDECAR" "sentinel-$i not lied"
    restore_steady_state || true
    return 0
  }
done

# Heal sequentially (avoid concurrent FAILOVER races - documented hazard).
for i in 1 2 3 4 5; do
  out=$(reconciler_once true "sentinel-$i")
  echo "$out" | tee "$ART_DIR/sidecar-$i-apply.log" >/dev/null
  if ! echo "$out" | grep -q 'heal succeeded'; then
    bad "SPEC-SIDECAR" "reconciler for sentinel-$i did not heal; tail=$(echo "$out" | tail -5 | tr '\n' ' | ')"
    restore_steady_state || true
    return 0
  fi
  # Local must match oracle; do not require peers yet.
  [[ "$(sentinel_master_host "sentinel-$i")" == "$oip" ]] || {
    bad "SPEC-SIDECAR" "sentinel-$i still wrong after its sidecar heal"
    restore_steady_state || true
    return 0
  }
  # Ensure this apply log only references local sentinel as heal target.
  if echo "$out" | grep -qE 'heal succeeded.*"sentinel":"sentinel-[^'"$i"']:'; then
    bad "SPEC-SIDECAR" "sidecar-$i heal log mentions other sentinel"
    restore_steady_state || true
    return 0
  fi
done

for i in 1 2 3 4 5; do
  [[ "$(sentinel_master_host "sentinel-$i")" == "$oip" ]] || {
    bad "SPEC-SIDECAR" "post-pass sentinel-$i != oracle"
    restore_steady_state || true
    return 0
  }
done

compose up -d reconciler-1 reconciler-2 reconciler-3 reconciler-4 reconciler-5 >/dev/null 2>&1 || true
ok "SPEC-SIDECAR 5x reconciler (1:1) each heals only local Sentinel"
