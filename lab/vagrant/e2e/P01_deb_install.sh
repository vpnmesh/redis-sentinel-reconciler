#!/usr/bin/env bash
# P01 — install the shipped .deb on a live Vagrant node (node-1).
#
# Needs: CLUSTER_N nodes already up (`make vagrant-up`). Builds dist/*.deb on
# the host, then dpkg -i inside node-1. Restores the lab overlay unit at the
# end so A01/A09 keep using APPLY_FLAG.
set -euo pipefail
VG="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib.sh
source "$VG/e2e/lib.sh"

ROOT="$(cd "$VG/../.." && pwd)"
NODE="${P01_NODE:-node-1}"
ART="$ART_ROOT/P01_deb_N${CLUSTER_N}_${ENGINE}_$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$ART"
DEB_STABLE="$ROOT/dist/redis-sentinel-reconciler_linux_amd64.deb"
IN_DEB="/opt/redis-sentinel-reconciler/dist/redis-sentinel-reconciler_linux_amd64.deb"
IN_SCRIPT="/opt/redis-sentinel-reconciler/lab/vagrant/provision/deb-install-on-node.sh"

log() { printf '[P01] %s\n' "$*" >&2; }

if ! docker inspect "rsr-vagrant-${NODE}" >/dev/null 2>&1; then
  log "FATAL: container rsr-vagrant-${NODE} is not running"
  log "bring the lab up first: CLUSTER_N=${CLUSTER_N} make vagrant-up"
  exit 1
fi

if [[ ! -f "$DEB_STABLE" ]]; then
  log "building .deb (make dist)"
  (cd "$ROOT" && ./scripts/package-linux-amd64.sh)
fi
[[ -f "$DEB_STABLE" ]] || {
  log "FATAL: $DEB_STABLE missing (need dpkg-deb on the host)"
  exit 1
}

FILL_REDIS=""
for i in $(seq 1 "$CLUSTER_N"); do
  ip="$(node_ip "$i")"
  [[ -n "$ip" ]] || { log "FATAL: no IP for node-$i"; exit 1; }
  FILL_REDIS+="${ip}:6379,"
done
FILL_REDIS="${FILL_REDIS%,}"
FILL_SENTINEL="${P01_SENTINEL_ADDR:-127.0.0.1:26379}"

log "node=$NODE CLUSTER_N=$CLUSTER_N REDIS_ADDRS=$FILL_REDIS"
log "deb=$DEB_STABLE"

docker cp "rsr-vagrant-${NODE}:/etc/systemd/system/redis-sentinel-reconciler.service" \
  "$ART/lab.service" 2>/dev/null || true
docker cp "rsr-vagrant-${NODE}:/etc/default/redis-sentinel-reconciler" \
  "$ART/lab.default" 2>/dev/null || true
[[ -f "$ART/lab.service" ]] || log "WARN: no lab overlay unit to restore"
[[ -f "$ART/lab.default" ]] || log "WARN: no lab /etc/default to restore"

restore_lab() {
  log "restore lab overlay on $NODE"
  node_exec "$NODE" bash -lc '
    systemctl stop redis-sentinel-reconciler 2>/dev/null || true
    dpkg --purge redis-sentinel-reconciler 2>/dev/null || true
    rm -f /usr/bin/reconciler
  ' || true
  if [[ -f "$ART/lab.service" ]]; then
    docker cp "$ART/lab.service" \
      "rsr-vagrant-${NODE}:/etc/systemd/system/redis-sentinel-reconciler.service" || true
  fi
  if [[ -f "$ART/lab.default" ]]; then
    docker cp "$ART/lab.default" \
      "rsr-vagrant-${NODE}:/etc/default/redis-sentinel-reconciler" || true
  fi
  node_exec "$NODE" bash -lc '
    systemctl daemon-reload
    systemctl reset-failed redis-sentinel-reconciler 2>/dev/null || true
    systemctl enable redis-sentinel-reconciler 2>/dev/null || true
    systemctl start redis-sentinel-reconciler 2>/dev/null || true
    systemctl is-active redis-sentinel-reconciler redis-server redis-sentinel || true
  ' || true
}

trap restore_lab EXIT

set +e
node_exec "$NODE" bash -lc "
  DEB='$IN_DEB' P01_REDIS_ADDRS='$FILL_REDIS' P01_SENTINEL_ADDR='$FILL_SENTINEL' \
  P01_MASTER_NAME='$MASTER_NAME' bash '$IN_SCRIPT'
"
rc=$?
set -e

node_exec "$NODE" bash -lc 'cat /tmp/rsr-p01.log 2>/dev/null; echo ----; cat /tmp/rsr-p01-empty.err 2>/dev/null' \
  >"$ART/node.log" 2>/dev/null || true
docker cp "rsr-vagrant-${NODE}:/tmp/rsr-p01-dpkg.out" "$ART/dpkg.out" 2>/dev/null || true
docker cp "rsr-vagrant-${NODE}:/tmp/rsr-p01-empty.err" "$ART/empty.err" 2>/dev/null || true
docker cp "rsr-vagrant-${NODE}:/tmp/rsr-p01-once.out" "$ART/once.out" 2>/dev/null || true

if [[ "$rc" -ne 0 ]]; then
  log "FAIL P01 (node exit $rc) ART=$ART"
  exit 1
fi
log "PASS P01 N=$CLUSTER_N ENGINE=$ENGINE ART=$ART"
exit 0
