#!/usr/bin/env bash
# A9 — operator wrong MONITOR × C0 vs C2 (sticky lie; peer Sentinels paused).
# Inject while reconciler stopped so the lie is observable; then C2 heals.
set -euo pipefail
VG="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib.sh
source "$VG/e2e/lib.sh"

CLUSTER_N="${CLUSTER_N:-3}"
ART="$ART_ROOT/A9_N${CLUSTER_N}_${ENGINE}_$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$ART"
WAIT_C2_SEC="${WAIT_C2_SEC:-45}"

log() { printf '[A9] %s\n' "$*" >&2; }

inject_sticky_lie() {
  local mip fake="$FAKE_MASTER_IP" ad
  read -r _node mip <<<"$(writable_master)"
  log "oracle=$mip; pause peer sentinels; stop reconciler; lie node-1 -> $fake"
  pause_peer_sentinels node-1
  node_exec node-1 systemctl stop redis-sentinel-reconciler 2>/dev/null || true
  point_sentinel node-1 "$fake"
  sleep 1
  ad=$(sentinel_ad node-1)
  [[ "$ad" == "$fake" ]] || { log "FATAL: lie did not stick ad=$ad"; start_all_sentinels; exit 1; }
  # stdout: oracle IP only (no logs)
  printf '%s\n' "$mip"
}

run_mode() {
  local mode="$1"
  log "mode=$mode ENGINE=$ENGINE"
  lab_tune_reconciler
  local mip ad jlog outcome t=0 since
  mip=$(inject_sticky_lie)
  since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if [[ "$mode" == "C0" ]]; then
    set_mode C0
    sleep 8
    ad=$(sentinel_ad node-1)
    jlog=$(node_exec node-1 journalctl -u redis-sentinel-reconciler --since "$since" --no-pager 2>/dev/null || true)
    if [[ "$ad" == "$FAKE_MASTER_IP" ]]; then outcome=BLACKHOLE
    else outcome=DESYNC_OR_STOCK; fi
  else
    set_mode C2
    while (( t < WAIT_C2_SEC )); do
      ad=$(sentinel_ad node-1)
      jlog=$(node_exec node-1 journalctl -u redis-sentinel-reconciler --since "$since" --no-pager 2>/dev/null || true)
      if [[ "$ad" == "$mip" ]] && echo "$jlog" | grep -q 'heal succeeded'; then
        break
      fi
      sleep 2
      t=$((t + 2))
    done
    ad=$(sentinel_ad node-1)
    jlog=$(node_exec node-1 journalctl -u redis-sentinel-reconciler --since "$since" --no-pager 2>/dev/null || true)
    if [[ "$ad" == "$mip" ]] && echo "$jlog" | grep -q 'heal succeeded'; then
      outcome=HEAL_APPLY
    elif [[ "$ad" == "$mip" ]]; then
      outcome=HEAL_OR_STOCK
    elif echo "$jlog" | grep -q 'would_heal'; then
      outcome=WOULD_HEAL_ONLY
    elif [[ "$ad" == "$FAKE_MASTER_IP" ]]; then
      outcome=STILL_BLACKHOLE
    else
      outcome=PARTIAL
    fi
  fi

  printf 'mode=%s engine=%s oracle=%s ad_after=%s outcome=%s wait_s=%s\n## journal\n%s\n' \
    "$mode" "$ENGINE" "$mip" "$ad" "$outcome" "$t" "$jlog" | tee "$ART/${mode}.txt"

  point_sentinel node-1 "$mip" || true
  start_all_sentinels
  sleep 3
}

run_mode C0
run_mode C2
CLUSTER_N="$CLUSTER_N" "$LABCTL" snap "$ART/topology-final.txt"
log "ART -> $ART"
grep -q 'outcome=BLACKHOLE' "$ART/C0.txt"
grep -qE 'outcome=HEAL_(APPLY|OR_STOCK)' "$ART/C2.txt"
log "PASS A9 N=$CLUSTER_N ENGINE=$ENGINE"
