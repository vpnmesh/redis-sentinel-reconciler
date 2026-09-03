#!/usr/bin/env bash
# Shared helpers for Vagrant matrix scenarios.
# shellcheck disable=SC2034
set -euo pipefail

VG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABCTL="$VG_DIR/scripts/labctl.sh"
CLUSTER_N="${CLUSTER_N:-3}"
MASTER_NAME="${MASTER_NAME:-mymaster}"
ENGINE="${ENGINE:-redis}"
QUORUM=$(( CLUSTER_N / 2 + 1 ))
FAKE_MASTER_IP="${FAKE_MASTER_IP:-10.255.255.254}"
ART_ROOT="${ART_ROOT:-$VG_DIR/artifacts/cells}"

node_exec() {
  local node="$1"; shift
  docker exec -e ENGINE="$ENGINE" "rsr-vagrant-${node}" "$@"
}

node_ip() {
  docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "rsr-vagrant-node-${1#node-}"
}

writable_master() {
  local i tip role
  for i in $(seq 1 "$CLUSTER_N"); do
    tip=$(node_ip "$i")
    if node_exec "node-${i}" redis-cli SET "vg:probe:$$" 1 EX 5 >/dev/null 2>&1; then
      role=$(node_exec "node-${i}" redis-cli INFO replication | tr -d '\r' | awk -F: '/^role:/{print $2}')
      if [[ "$role" == "master" ]]; then
        echo "node-${i} ${tip}"
        return 0
      fi
    fi
  done
  return 1
}

sentinel_ad() {
  local node="${1:-node-1}"
  node_exec "$node" redis-cli -p 26379 SENTINEL get-master-addr-by-name "$MASTER_NAME" 2>/dev/null | head -1 | tr -d '\r'
}

pause_peer_sentinels() {
  local i keep="${1:-node-1}"
  for i in $(seq 1 "$CLUSTER_N"); do
    local n="node-${i}"
    [[ "$n" == "$keep" ]] && continue
    node_exec "$n" systemctl stop redis-sentinel 2>/dev/null || true
  done
}

start_all_sentinels() {
  local i
  for i in $(seq 1 "$CLUSTER_N"); do
    node_exec "node-${i}" systemctl start redis-sentinel 2>/dev/null || true
  done
}

point_sentinel() {
  local node="$1" ip="$2"
  node_exec "$node" redis-cli -p 26379 SENTINEL REMOVE "$MASTER_NAME" >/dev/null 2>&1 || true
  node_exec "$node" redis-cli -p 26379 SENTINEL MONITOR "$MASTER_NAME" "$ip" 6379 "$QUORUM" >/dev/null
}

set_mode() {
  CLUSTER_N="$CLUSTER_N" "$LABCTL" mode "$1"
}

# Lab matrix: short cooldown so apply heals within cell wall time.
# Does NOT start units — call before/after mode; C0 must stay stopped.
lab_tune_reconciler() {
  local i restart="${1:-}"
  for i in $(seq 1 "$CLUSTER_N"); do
    node_exec "node-${i}" bash -lc '
      sed -i "s/^HEAL_COOLDOWN=.*/HEAL_COOLDOWN=0/" /etc/default/redis-sentinel-reconciler
      sed -i "s/^INTERVAL=.*/INTERVAL=2s/" /etc/default/redis-sentinel-reconciler
    '
    if [[ "$restart" == "restart" ]]; then
      node_exec "node-${i}" systemctl restart redis-sentinel-reconciler 2>/dev/null || true
    fi
  done
}

save_cell() {
  local dir="$1" body="$2"
  mkdir -p "$dir"
  printf '%s\n' "$body" >"$dir/cell.txt"
}

journal_reconciler() {
  node_exec "${1:-node-1}" journalctl -u redis-sentinel-reconciler -n "${2:-60}" --no-pager 2>/dev/null || true
}
