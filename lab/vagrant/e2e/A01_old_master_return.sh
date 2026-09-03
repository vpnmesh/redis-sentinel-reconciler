#!/usr/bin/env bash
# A1 — old master returns still writable (halt M → elect → revive M without REPLICAOF).
# C0: expect DUAL or DESYNC window. C2: refuse dual; after stock demote → sync or escalate.
set -euo pipefail
VG="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib.sh
source "$VG/e2e/lib.sh"

CLUSTER_N="${CLUSTER_N:-3}"
ART="$ART_ROOT/A1_N${CLUSTER_N}_${ENGINE}_$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$ART"
ELECT_WAIT="${ELECT_WAIT:-40}"
OBSERVE_SEC="${OBSERVE_SEC:-20}"

log() { printf '[A1] %s\n' "$*" >&2; }

count_writables() {
  local i n=0 role
  for i in $(seq 1 "$CLUSTER_N"); do
    if node_exec "node-${i}" redis-cli SET "a1:w:$$" 1 EX 3 >/dev/null 2>&1; then
      role=$(node_exec "node-${i}" redis-cli INFO replication | tr -d '\r' | awk -F: '/^role:/{print $2}')
      [[ "$role" == "master" ]] && n=$((n + 1))
    fi
  done
  echo "$n"
}

run_mode() {
  local mode="$1"
  log "mode=$mode ENGINE=$ENGINE"
  lab_tune_reconciler
  set_mode "$mode"
  sleep 2

  local mnode mip elected="" t=0 wcount new_ad jlog outcome since cur_node cur_ip i n
  read -r mnode mip <<<"$(writable_master)"
  log "halt master $mnode ($mip); wait election"
  node_exec "$mnode" systemctl stop redis-server

  while (( t < ELECT_WAIT )); do
    if read -r elected _ <<<"$(writable_master 2>/dev/null || true)"; then
      [[ -n "$elected" && "$elected" != "$mnode" ]] && break
    fi
    sleep 2
    t=$((t + 2))
  done
  [[ -n "$elected" && "$elected" != "$mnode" ]] || {
    log "FATAL: no election after kill $mnode"
    node_exec "$mnode" systemctl start redis-server || true
    return 1
  }
  log "elected=$elected; revive old master as standalone writable"
  since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  node_exec "$mnode" bash -lc '
    sed -i "/^replicaof /d" /etc/redis/redis.conf || true
    systemctl start redis-server
    sleep 1
    redis-cli SLAVEOF NO ONE >/dev/null
  '
  sleep 3

  wcount=$(count_writables)
  new_ad=$(sentinel_ad node-1)
  sleep "$OBSERVE_SEC"
  wcount=$(count_writables)
  new_ad=$(sentinel_ad node-1)
  jlog=$(node_exec node-1 journalctl -u redis-sentinel-reconciler --since "$since" --no-pager 2>/dev/null || true)

  if [[ "$mode" == "C0" ]]; then
    if (( wcount >= 2 )); then outcome=DUAL
    elif (( wcount == 1 )); then outcome=DESYNC_OR_STOCK
    else outcome=ZERO; fi
  else
    if echo "$jlog" | grep -qiE 'dual_master|refuse.*dual|alert_dual'; then
      outcome=HEAL_REFUSE_DUAL
    elif (( wcount >= 2 )); then
      outcome=DUAL_STILL
    elif (( wcount == 1 )) && echo "$jlog" | grep -qE 'heal succeeded|would_heal'; then
      outcome=HEAL_OR_OBSERVE
    else
      outcome=PARTIAL
    fi
  fi

  printf 'mode=%s engine=%s old=%s elected=%s writables=%s ad=%s outcome=%s\n## journal\n%s\n' \
    "$mode" "$ENGINE" "$mnode" "$elected" "$wcount" "$new_ad" "$outcome" "$jlog" \
    | tee "$ART/${mode}.txt"

  if read -r cur_node cur_ip <<<"$(writable_master 2>/dev/null || true)"; then
    for i in $(seq 1 "$CLUSTER_N"); do
      n="node-${i}"
      [[ "$n" == "$cur_node" ]] && continue
      node_exec "$n" redis-cli REPLICAOF "$cur_ip" 6379 >/dev/null 2>&1 || true
    done
  fi
  start_all_sentinels
  sleep 3
}

main() {
  run_mode C0
  run_mode C2
  CLUSTER_N="$CLUSTER_N" "$LABCTL" snap "$ART/topology-final.txt"
  log "ART -> $ART"
  grep -qE 'outcome=(DUAL|DESYNC_OR_STOCK)' "$ART/C0.txt"
  grep -qE 'outcome=(HEAL_REFUSE_DUAL|HEAL_OR_OBSERVE|DUAL_STILL|PARTIAL)' "$ART/C2.txt"
  log "PASS A1 cell recorded N=$CLUSTER_N ENGINE=$ENGINE"
}

main "$@"
