#!/usr/bin/env bash
# Host-side helpers for Vagrant Docker lab (run from lab/vagrant or via make).
set -euo pipefail

VG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# scripts/ -> vagrant/ -> lab/ -> module root
ROOT_DIR="$(cd "$VG_DIR/../../.." && pwd)"
ART_DIR="${ART_DIR:-$VG_DIR/artifacts}"
CLUSTER_N="${CLUSTER_N:-5}"
MASTER_NAME="${MASTER_NAME:-mymaster}"
mkdir -p "$ART_DIR"

cd "$VG_DIR"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

vagrant_n() {
  CLUSTER_N="$CLUSTER_N" vagrant "$@"
}

build_bin() {
  log "building reconciler into $ROOT_DIR/bin/reconciler"
  mkdir -p "$ROOT_DIR/bin"
  (cd "$ROOT_DIR" && CGO_ENABLED=0 go build -o bin/reconciler ./cmd/reconciler)
}

node_exec() {
  local node="$1"; shift
  # Prefer docker exec (faster/reliable than vagrant ssh under docker provider).
  local cname="rsr-vagrant-${node}"
  if docker ps -q --filter "name=^/${cname}$" | grep -q .; then
    docker exec "$cname" "$@"
  else
    CLUSTER_N="$CLUSTER_N" vagrant ssh "$node" -c "$*"
  fi
}

snap_topology() {
  local out="$1"
  {
    echo "### topology $(date -u +%Y-%m-%dT%H:%M:%SZ) CLUSTER_N=$CLUSTER_N"
    local i
    for i in $(seq 1 "$CLUSTER_N"); do
      local n="node-${i}"
      echo "## $n"
      node_exec "$n" bash -lc 'hostname; hostname -I; systemctl is-active redis-server redis-sentinel redis-sentinel-reconciler 2>/dev/null || true' || echo "DOWN"
      node_exec "$n" redis-cli INFO replication 2>/dev/null | tr -d '\r' | grep -E '^(role|master_host|master_link_status):' || true
      node_exec "$n" bash -lc "redis-cli -p 26379 SENTINEL get-master-addr-by-name $MASTER_NAME" 2>/dev/null | tr -d '\r' || true
    done
  } | tee "$out"
}

smoke() {
  log "smoke: ping redis + sentinel on all nodes"
  local i fail=0
  for i in $(seq 1 "$CLUSTER_N"); do
    local n="node-${i}"
    if node_exec "$n" redis-cli PING 2>/dev/null | grep -q PONG; then
      log "OK $n redis"
    else
      log "FAIL $n redis"; fail=1
    fi
    if node_exec "$n" redis-cli -p 26379 PING 2>/dev/null | grep -q PONG; then
      log "OK $n sentinel"
    else
      log "FAIL $n sentinel"; fail=1
    fi
  done
  snap_topology "$ART_DIR/smoke-topology-$(date -u +%Y%m%dT%H%M%SZ).txt"
  return "$fail"
}

# Halt / up whole machine (docker stop/start via vagrant).
halt_node() { CLUSTER_N="$CLUSTER_N" vagrant halt "$1"; }
up_node() { CLUSTER_N="$CLUSTER_N" vagrant up "$1" --provider=docker; }

set_reconciler_mode() {
  # C0=stop, C1=dry-run, C2=apply
  local mode="$1" i n
  for i in $(seq 1 "$CLUSTER_N"); do
    n="node-${i}"
    case "$mode" in
      C0)
        node_exec "$n" bash -lc '
          sed -i "s/^APPLY_FLAG=.*/APPLY_FLAG=/" /etc/default/redis-sentinel-reconciler
          systemctl stop redis-sentinel-reconciler 2>/dev/null || true
          systemctl reset-failed redis-sentinel-reconciler 2>/dev/null || true
        '
        ;;
      C1)
        node_exec "$n" bash -lc 'sed -i "s/^APPLY_FLAG=.*/APPLY_FLAG=/" /etc/default/redis-sentinel-reconciler; systemctl restart redis-sentinel-reconciler'
        ;;
      C2)
        node_exec "$n" bash -lc 'sed -i "s/^APPLY_FLAG=.*/APPLY_FLAG=--apply/" /etc/default/redis-sentinel-reconciler; systemctl restart redis-sentinel-reconciler'
        ;;
      *) log "unknown mode $mode"; return 1 ;;
    esac
  done
}

# After provision / chaos: one writable master (node-1) + all Sentinel ads → it.
restore_steady() {
  local quorum=$(( CLUSTER_N / 2 + 1 ))
  local mip i n tip
  mip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' rsr-vagrant-node-1)
  log "restore_steady master=node-1 ($mip) quorum=$quorum"
  node_exec node-1 bash -lc 'sed -i "/^replicaof /d" /etc/redis/redis.conf; redis-cli SLAVEOF NO ONE'
  for i in $(seq 2 "$CLUSTER_N"); do
    n="node-${i}"
    node_exec "$n" bash -lc "sed -i '/^replicaof /d' /etc/redis/redis.conf; echo 'replicaof ${mip} 6379' >> /etc/redis/redis.conf; redis-cli REPLICAOF ${mip} 6379"
  done
  sleep 2
  for i in $(seq 1 "$CLUSTER_N"); do
    n="node-${i}"
    node_exec "$n" redis-cli -p 26379 SENTINEL REMOVE "$MASTER_NAME" >/dev/null 2>&1 || true
    node_exec "$n" redis-cli -p 26379 SENTINEL MONITOR "$MASTER_NAME" "$mip" 6379 "$quorum" >/dev/null
  done
  node_exec node-1 redis-cli SET rsr:steady 1 EX 60 >/dev/null
  snap_topology "$ART_DIR/steady-$(date -u +%Y%m%dT%H%M%SZ).txt"
}

case "${1:-}" in
  build-bin) build_bin ;;
  smoke) smoke ;;
  snap) snap_topology "${2:-$ART_DIR/topology.txt}" ;;
  halt) halt_node "$2" ;;
  up) up_node "$2" ;;
  mode) set_reconciler_mode "$2" ;;
  restore-steady) restore_steady ;;
  *)
    echo "usage: $0 {build-bin|smoke|snap [file]|halt node-N|up node-N|mode C0|C1|C2|restore-steady}"
    exit 2
    ;;
esac
