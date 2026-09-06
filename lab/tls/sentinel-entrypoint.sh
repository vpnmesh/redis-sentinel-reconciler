#!/bin/sh
set -eu
SRC="${SENTINEL_CONF_SRC:-/usr/local/etc/redis/sentinel.conf}"
DEST="${SENTINEL_CONF_DEST:-/data/sentinel.conf}"
if [ -f "$DEST" ] && grep -q 'sentinel monitor' "$DEST" 2>/dev/null; then
  exec redis-sentinel "$DEST"
fi
cp "$SRC" "$DEST"
exec redis-sentinel "$DEST"
