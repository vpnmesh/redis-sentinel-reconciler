#!/usr/bin/env bash
# Provision all rsr-vagrant-node-* via docker exec (Vagrant SSH to systemd images is flaky).
# ENGINE=redis (default) | valkey
set -euo pipefail
CLUSTER_N="${CLUSTER_N:-5}"
MASTER_NAME="${MASTER_NAME:-mymaster}"
ENGINE="${ENGINE:-redis}"
LAB_HEAL_COOLDOWN="${LAB_HEAL_COOLDOWN:-0}"
LAB_INTERVAL="${LAB_INTERVAL:-5s}"
QUORUM=$(( CLUSTER_N / 2 + 1 ))
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# Inside nodes the repo is bind-mounted at /opt/redis-sentinel-reconciler (ro).
IN_REPO="/opt/redis-sentinel-reconciler"
SCRIPT="$IN_REPO/lab/vagrant/provision/bootstrap.sh"
FIX="$IN_REPO/lab/vagrant/provision/fix-peers.sh"

if [[ "$ENGINE" == "valkey" && ! -x "$ROOT/lab/vagrant/bins/valkey/valkey-server" ]]; then
  echo "Valkey bins missing — run: make vagrant-engine-bins ENGINE=valkey"
  exit 1
fi

for i in $(seq 1 "$CLUSTER_N"); do
  c="rsr-vagrant-node-${i}"
  echo "=== bootstrap $c ENGINE=$ENGINE ==="
  docker exec \
    -e NODE_INDEX="$i" -e CLUSTER_N="$CLUSTER_N" -e QUORUM="$QUORUM" \
    -e MASTER_NAME="$MASTER_NAME" -e ENGINE="$ENGINE" \
    -e LAB_HEAL_COOLDOWN="$LAB_HEAL_COOLDOWN" -e LAB_INTERVAL="$LAB_INTERVAL" \
    "$c" bash "$SCRIPT"
done
for i in $(seq 1 "$CLUSTER_N"); do
  c="rsr-vagrant-node-${i}"
  docker exec -e NODE_INDEX="$i" -e CLUSTER_N="$CLUSTER_N" -e QUORUM="$QUORUM" -e MASTER_NAME="$MASTER_NAME" \
    "$c" bash "$FIX" || true
done
echo "provision-all done CLUSTER_N=$CLUSTER_N QUORUM=$QUORUM ENGINE=$ENGINE"
