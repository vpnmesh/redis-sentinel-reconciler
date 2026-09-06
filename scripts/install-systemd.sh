#!/usr/bin/env bash
# Install the linux/amd64 sidecar onto a systemd host.
# Run from an extracted release tarball (reconciler + systemd/ next to this script)
# or from this git tree after: go build -o reconciler ./cmd/reconciler
#
#   sudo ./install-systemd.sh
#
# Does not start the unit. Fill SENTINEL_ADDR (this host's Sentinel) and
# REDIS_ADDRS (every data node that can become master), then:
#   sudo systemctl enable --now redis-sentinel-reconciler
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DESTDIR="${DESTDIR:-}"
PREFIX="${PREFIX:-/usr}"
UNIT_DIR="${UNIT_DIR:-/lib/systemd/system}"
CONF_PATH="${CONF_PATH:-/etc/default/redis-sentinel-reconciler}"

die() { printf '%s\n' "$*" >&2; exit 1; }

if [[ -z "$DESTDIR" && "$(id -u)" -ne 0 ]]; then
  die "run as root (or set DESTDIR= for a staged install)"
fi

find_bin() {
  local c
  for c in \
    "${BIN:-}" \
    "$HERE/reconciler" \
    "$HERE/../reconciler" \
    "$PWD/reconciler"; do
    [[ -n "$c" && -f "$c" && -x "$c" ]] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

find_unit() {
  local c
  for c in \
    "$HERE/systemd/redis-sentinel-reconciler.service" \
    "$HERE/../deploy/systemd/redis-sentinel-reconciler.service" \
    "$HERE/deploy/systemd/redis-sentinel-reconciler.service"; do
    [[ -f "$c" ]] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

find_default() {
  local c
  for c in \
    "$HERE/systemd/redis-sentinel-reconciler.default" \
    "$HERE/../deploy/systemd/redis-sentinel-reconciler.default" \
    "$HERE/deploy/systemd/redis-sentinel-reconciler.default"; do
    [[ -f "$c" ]] && { printf '%s\n' "$c"; return 0; }
  done
  return 1
}

BIN_SRC="$(find_bin)" || die "no reconciler binary next to this script (extract the release tarball, or go build -o reconciler ./cmd/reconciler)"
UNIT_SRC="$(find_unit)" || die "missing systemd unit file"
DEF_SRC="$(find_default)" || die "missing systemd default file"

BIN_DST="${DESTDIR}${PREFIX}/bin/reconciler"
UNIT_DST="${DESTDIR}${UNIT_DIR}/redis-sentinel-reconciler.service"
CONF_DST="${DESTDIR}${CONF_PATH}"

install -d "$(dirname "$BIN_DST")" "$(dirname "$UNIT_DST")" "$(dirname "$CONF_DST")"
install -m 0755 "$BIN_SRC" "$BIN_DST"
install -m 0644 "$UNIT_SRC" "$UNIT_DST"

if [[ -f "$CONF_DST" ]]; then
  printf 'keeping existing %s\n' "$CONF_DST"
else
  install -m 0640 "$DEF_SRC" "$CONF_DST"
fi

if [[ -z "$DESTDIR" ]]; then
  if ! getent passwd redis >/dev/null 2>&1; then
    if command -v adduser >/dev/null 2>&1; then
      adduser --system --group --no-create-home --home /nonexistent \
        --shell /usr/sbin/nologin redis
    else
      printf 'no redis user and no adduser; unit User=redis may fail to start\n' >&2
    fi
  fi
  if getent group redis >/dev/null 2>&1; then
    chown root:redis "$CONF_DST" 2>/dev/null || chown root:root "$CONF_DST"
  fi
  chmod 0640 "$CONF_DST" || true
  if [[ -d /run/systemd/system ]]; then
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
fi

printf '\nInstalled %s and %s\n' "$BIN_DST" "$UNIT_DST"
printf '1. Edit %s\n' "$CONF_DST"
printf '     SENTINEL_ADDR = this host'\''s Sentinel (host:26379)\n'
printf '     REDIS_ADDRS   = every data node that can become master (port 6379)\n'
printf '2. sudo systemctl enable --now redis-sentinel-reconciler\n'
printf '3. journalctl -u redis-sentinel-reconciler -f\n'
printf 'Leave APPLY=false until you have watched ticks.\n'
