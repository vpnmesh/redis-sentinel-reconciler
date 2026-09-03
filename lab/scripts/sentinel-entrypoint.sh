#!/bin/sh
set -eu

SRC="${SENTINEL_CONF_SRC:-/usr/local/etc/redis/sentinel.conf}"
DEST="${SENTINEL_CONF_DEST:-/data/sentinel.conf}"

# On restart, reuse the runtime conf Sentinel already rewrote (failover state).
# Do not re-bootstrap from the image template - that requires redis-1 DNS and
# resets the monitor target after master failover (breaks lab chaos / real restarts).
if [ -f "$DEST" ] && grep -q 'sentinel monitor' "$DEST" 2>/dev/null; then
  exec redis-sentinel "$DEST"
fi

if ! getent hosts redis-1 >/dev/null 2>&1; then
  echo "ERROR: cannot resolve redis-1 via getent" >&2
  exit 1
fi

MASTER_IP="$(getent ahostsv4 redis-1 | awk 'NR==1 {print $1}')"
if [ -z "$MASTER_IP" ]; then
  echo "ERROR: no IPv4 address for redis-1" >&2
  exit 1
fi

sed "s/ redis-1 / ${MASTER_IP} /" "$SRC" > "$DEST"
exec redis-sentinel "$DEST"
