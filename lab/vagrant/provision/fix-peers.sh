#!/usr/bin/env bash
# Re-write REDIS_ADDRS and sentinel monitor target using live container IPs.
set -euo pipefail
CLUSTER_N="${CLUSTER_N:?}"
MASTER_NAME="${MASTER_NAME:-mymaster}"
QUORUM="${QUORUM:?}"
NODE_INDEX="${NODE_INDEX:?}"

addrs=()
for j in $(seq 1 "$CLUSTER_N"); do
  cname="rsr-vagrant-node-${j}"
  ip="$(getent ahostsv4 "$cname" 2>/dev/null | awk '{print $1; exit}' || true)"
  if [[ -z "$ip" ]]; then
    ip="$(getent ahostsv4 "node-${j}" 2>/dev/null | awk '{print $1; exit}' || true)"
  fi
  # Fallback: docker network DNS may not resolve; probe via ping of known peers from env.
  [[ -n "$ip" ]] || ip="node-${j}"
  addrs+=("${ip}:6379")
done

IFS=,; REDIS_ADDRS="${addrs[*]}"; unset IFS
MASTER_IP="${addrs[0]%%:*}"
if ! redis-cli -h "$MASTER_IP" SET "rsr:peerfix:$$" 1 EX 5 >/dev/null 2>&1; then
  for a in "${addrs[@]}"; do
    tip="${a%%:*}"
    if redis-cli -h "$tip" SET "rsr:peerfix:$$" 1 EX 5 >/dev/null 2>&1; then
      MASTER_IP="$tip"
      break
    fi
  done
fi

if [[ -f /etc/default/redis-sentinel-reconciler ]]; then
  sed -i "s|^REDIS_ADDRS=.*|REDIS_ADDRS=${REDIS_ADDRS}|" /etc/default/redis-sentinel-reconciler
fi

if redis-cli -p 26379 PING 2>/dev/null | grep -q PONG; then
  redis-cli -p 26379 SENTINEL REMOVE "$MASTER_NAME" >/dev/null 2>&1 || true
  redis-cli -p 26379 SENTINEL MONITOR "$MASTER_NAME" "$MASTER_IP" 6379 "$QUORUM" >/dev/null || true
fi

if [[ -x /usr/local/bin/reconciler ]]; then
  systemctl restart redis-sentinel-reconciler || true
fi
echo "fix-peers node-$NODE_INDEX MASTER_IP=$MASTER_IP REDIS_ADDRS=$REDIS_ADDRS"
