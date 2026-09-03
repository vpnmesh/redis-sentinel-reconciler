#!/usr/bin/env bash
# Bootstrap one Vagrant Docker node: data-plane + Sentinel + reconciler (systemd).
# ENGINE=redis (default) | valkey — Redis-compatible Sentinel stack.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
NODE_INDEX="${NODE_INDEX:?}"
CLUSTER_N="${CLUSTER_N:?}"
QUORUM="${QUORUM:?}"
MASTER_NAME="${MASTER_NAME:-mymaster}"
ENGINE="${ENGINE:-redis}"
REPO="/opt/redis-sentinel-reconciler"
LAB_HEAL_COOLDOWN="${LAB_HEAL_COOLDOWN:-0}"
LAB_INTERVAL="${LAB_INTERVAL:-5s}"

log() { printf '[provision node-%s engine=%s] %s\n' "$NODE_INDEX" "$ENGINE" "$*"; }

case "$ENGINE" in
  redis|valkey) ;;
  *) log "FATAL: ENGINE must be redis|valkey"; exit 2 ;;
esac

# Paths / unit names stay redis-* for systemd familiarity; binaries follow ENGINE.
CONF_DIR=/etc/redis
DATA_DIR=/var/lib/redis
LOG_DIR=/var/log/redis
SVC_USER=redis

install -d -m 0755 "$CONF_DIR" "$DATA_DIR" "$LOG_DIR"
id "$SVC_USER" >/dev/null 2>&1 || useradd --system --home "$DATA_DIR" --shell /usr/sbin/nologin "$SVC_USER"
chown -R "$SVC_USER:$SVC_USER" "$DATA_DIR" "$LOG_DIR"

apt-get update -qq
apt-get install -y -qq curl ca-certificates >/dev/null

SERVER_BIN=""
CLI_BIN=""

install_redis_apt() {
  apt-get install -y -qq redis-server redis-tools >/dev/null
  systemctl disable --now redis-server 2>/dev/null || true
  systemctl disable --now redis-sentinel 2>/dev/null || true
  SERVER_BIN=/usr/bin/redis-server
  CLI_BIN=/usr/bin/redis-cli
}

install_valkey_bins() {
  # Prefer host-fetched bins mounted from repo (make vagrant-engine-bins).
  local src="$REPO/lab/vagrant/bins/valkey"
  if [[ -x "$src/valkey-server" && -x "$src/valkey-cli" ]]; then
    install -m 0755 "$src/valkey-server" /usr/local/bin/valkey-server
    install -m 0755 "$src/valkey-cli" /usr/local/bin/valkey-cli
    ln -sfn /usr/local/bin/valkey-server /usr/local/bin/redis-server
    ln -sfn /usr/local/bin/valkey-cli /usr/local/bin/redis-cli
    SERVER_BIN=/usr/local/bin/valkey-server
    CLI_BIN=/usr/local/bin/valkey-cli
    return 0
  fi
  # Fallback: try distro package if present.
  if apt-get install -y -qq valkey 2>/dev/null; then
    SERVER_BIN="$(command -v valkey-server || command -v redis-server)"
    CLI_BIN="$(command -v valkey-cli || command -v redis-cli)"
    return 0
  fi
  log "FATAL: Valkey bins missing. On host run: make vagrant-engine-bins ENGINE=valkey"
  exit 1
}

log "install engine=$ENGINE"
if [[ "$ENGINE" == "redis" ]]; then
  install_redis_apt
else
  install_valkey_bins
fi
[[ -x "$SERVER_BIN" ]] || { log "FATAL: no server bin"; exit 1; }
[[ -x "$CLI_BIN" ]] || { log "FATAL: no cli bin"; exit 1; }

REDIS_ADDRS=""
MASTER_SEED_IP=""
for j in $(seq 1 "$CLUSTER_N"); do
  hn="node-${j}"
  ip="$(getent ahostsv4 "rsr-vagrant-${hn}" 2>/dev/null | awk '{print $1; exit}' || true)"
  [[ -z "$ip" ]] && ip="$(getent ahostsv4 "$hn" 2>/dev/null | awk '{print $1; exit}' || true)"
  if [[ -n "$ip" ]]; then
    REDIS_ADDRS+="${ip}:6379,"
    [[ "$j" == "1" ]] && MASTER_SEED_IP="$ip"
  else
    REDIS_ADDRS+="${hn}:6379,"
  fi
done
REDIS_ADDRS="${REDIS_ADDRS%,}"

MY_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[[ -n "$MY_IP" ]] || MY_IP="127.0.0.1"
# Valkey 8 refuses MONITOR/replicaof hostnames it cannot resolve at config load.
[[ -n "$MASTER_SEED_IP" ]] || MASTER_SEED_IP="$MY_IP"

cat >"$CONF_DIR/redis.conf" <<EOF
bind 0.0.0.0
protected-mode no
port 6379
dir ${DATA_DIR}
appendonly yes
daemonize no
logfile ${LOG_DIR}/server.log
EOF
if [[ "$NODE_INDEX" != "1" ]]; then
  echo "replicaof ${MASTER_SEED_IP} 6379" >>"$CONF_DIR/redis.conf"
fi

# Redis 6.x (Ubuntu 22.04 apt) rejects `resolve-hostnames` (unknown directive → Sentinel crash).
# Valkey 8 accepts it; still prefer seed IP for MONITOR so config loads without DNS.
RESOLVE_HOSTNAMES_LINE=""
if [[ "$ENGINE" == "valkey" ]]; then
  RESOLVE_HOSTNAMES_LINE="sentinel resolve-hostnames yes"
fi

cat >"$CONF_DIR/sentinel.conf" <<EOF
port 26379
dir /tmp
${RESOLVE_HOSTNAMES_LINE}
sentinel monitor ${MASTER_NAME} ${MASTER_SEED_IP} 6379 ${QUORUM}
sentinel down-after-milliseconds ${MASTER_NAME} 5000
sentinel failover-timeout ${MASTER_NAME} 30000
sentinel parallel-syncs ${MASTER_NAME} 1
logfile ${LOG_DIR}/sentinel.log
daemonize no
EOF
chown "$SVC_USER:$SVC_USER" "$CONF_DIR/redis.conf" "$CONF_DIR/sentinel.conf"

cat >/etc/systemd/system/redis-server.service <<EOF
[Unit]
Description=Data-plane server (${ENGINE}) RSR vagrant lab
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SVC_USER}
Group=${SVC_USER}
ExecStart=${SERVER_BIN} ${CONF_DIR}/redis.conf
Restart=on-failure
RestartSec=2
LimitNOFILE=65535
Environment=ENGINE=${ENGINE}

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/redis-sentinel.service <<EOF
[Unit]
Description=Sentinel (${ENGINE}) RSR vagrant lab
After=network-online.target redis-server.service
Wants=network-online.target

[Service]
Type=simple
User=${SVC_USER}
Group=${SVC_USER}
# redis-server and valkey-server both accept --sentinel
ExecStart=${SERVER_BIN} ${CONF_DIR}/sentinel.conf --sentinel
Restart=on-failure
RestartSec=2
Environment=ENGINE=${ENGINE}

[Install]
WantedBy=multi-user.target
EOF

if [[ -x "${REPO}/bin/reconciler" ]]; then
  install -m 0755 "${REPO}/bin/reconciler" /usr/local/bin/reconciler
fi

cat >/etc/default/redis-sentinel-reconciler <<EOF
ENGINE=${ENGINE}
SENTINEL_ADDR=127.0.0.1:26379
MASTER_NAME=${MASTER_NAME}
REDIS_ADDRS=${REDIS_ADDRS}
INTERVAL=${LAB_INTERVAL}
HEAL_COOLDOWN=${LAB_HEAL_COOLDOWN}
HEAL_LEASE=true
EQUAL_EPOCH_ESCALATE=true
METRICS_ADDR=127.0.0.1:9090
REDIS_PASSWORD=
SENTINEL_PASSWORD=
# C1 dry-run: APPLY_FLAG=
# C2 apply: APPLY_FLAG=--apply
APPLY_FLAG=
EOF

cat >/etc/systemd/system/redis-sentinel-reconciler.service <<'EOF'
[Unit]
Description=Sentinel ad reconciler (Redis-compatible / Valkey)
Documentation=file:///opt/redis-sentinel-reconciler/lab/vagrant/PLAN.md
After=network-online.target redis-sentinel.service
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-/etc/default/redis-sentinel-reconciler
ExecStart=/usr/local/bin/reconciler \
  --sentinel-addr=${SENTINEL_ADDR} \
  --master-name=${MASTER_NAME} \
  --local-sentinel \
  --redis-addrs=${REDIS_ADDRS} \
  --interval=${INTERVAL} \
  --heal-cooldown=${HEAL_COOLDOWN} \
  --heal-lease=${HEAL_LEASE} \
  --equal-epoch-escalate=${EQUAL_EPOCH_ESCALATE} \
  --metrics-addr=${METRICS_ADDR} \
  --redis-password=${REDIS_PASSWORD} \
  --sentinel-password=${SENTINEL_PASSWORD} \
  ${APPLY_FLAG}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable redis-server redis-sentinel
systemctl restart redis-server
sleep 1
systemctl restart redis-sentinel

if [[ -x /usr/local/bin/reconciler ]]; then
  systemctl enable redis-sentinel-reconciler
  systemctl restart redis-sentinel-reconciler || true
fi

log "done MY_IP=${MY_IP} QUORUM=${QUORUM} REDIS_ADDRS=${REDIS_ADDRS} SERVER=${SERVER_BIN}"
systemctl is-active redis-server redis-sentinel || true
