#!/usr/bin/env bash
# Runs *inside* a Vagrant systemd node. Installs the shipped .deb and checks
# the documented empty-config fail, then a start after filling addresses.
#
# Env: DEB, P01_REDIS_ADDRS, P01_SENTINEL_ADDR, P01_MASTER_NAME
# Do not pass REDIS_ADDRS / SENTINEL_ADDR — the binary reads those names.
set -euo pipefail

DEB="${DEB:?set DEB to the .deb path (repo mount under /opt)}"
FILL_REDIS="${P01_REDIS_ADDRS:?}"
FILL_SENTINEL="${P01_SENTINEL_ADDR:-127.0.0.1:26379}"
FILL_MASTER="${P01_MASTER_NAME:-mymaster}"
LOG="${P01_LOG:-/tmp/rsr-p01.log}"

log() { printf '[p01] %s\n' "$*" | tee -a "$LOG"; }
fail() { log "FAIL: $*"; exit 1; }

# Product env names — must not leak into empty-config checks.
clear_product_env() {
  unset SENTINEL_ADDR REDIS_ADDRS MASTER_NAME APPLY \
    RSR_SENTINEL_ADDR RSR_REDIS_ADDRS RSR_MASTER_NAME RSR_APPLY \
    APPLY_FLAG RSR_APPLY_FLAG 2>/dev/null || true
}

: >"$LOG"
[[ -f "$DEB" ]] || fail "deb not found: $DEB"

systemctl stop redis-sentinel-reconciler 2>/dev/null || true
systemctl reset-failed redis-sentinel-reconciler 2>/dev/null || true

# Lab overlay in /etc shadows the packaged unit in /lib. Remove it so dpkg's
# unit is the one systemd uses. Conffile must go too, or dpkg keeps the filled
# lab file and the empty-config check is skipped.
rm -f /etc/systemd/system/redis-sentinel-reconciler.service
rm -f /etc/systemd/system/multi-user.target.wants/redis-sentinel-reconciler.service
rm -f /etc/default/redis-sentinel-reconciler
systemctl daemon-reload || true

export DEBIAN_FRONTEND=noninteractive
dpkg -i "$DEB" > /tmp/rsr-p01-dpkg.out 2>&1 || {
  cat /tmp/rsr-p01-dpkg.out
  fail "dpkg -i failed"
}
cat /tmp/rsr-p01-dpkg.out | tee -a "$LOG"

grep -q 'SENTINEL_ADDR = this host' /tmp/rsr-p01-dpkg.out \
  || fail "postinst did not explain SENTINEL_ADDR"
grep -q 'can become master' /tmp/rsr-p01-dpkg.out \
  || fail "postinst did not explain REDIS_ADDRS"

[[ -x /usr/bin/reconciler ]] || fail "missing /usr/bin/reconciler"
dpkg -s redis-sentinel-reconciler >/dev/null || fail "package not installed"

unit="$(systemctl cat redis-sentinel-reconciler)"
echo "$unit" | grep -q 'ExecStart=/usr/bin/reconciler --config /etc/default/redis-sentinel-reconciler' \
  || fail "packaged unit ExecStart is not --config /usr/bin/reconciler"
if echo "$unit" | grep -qE '^EnvironmentFile='; then
  fail "packaged unit must not set EnvironmentFile="
fi
if echo "$unit" | grep -q 'APPLY_FLAG'; then
  fail "packaged unit must not use APPLY_FLAG"
fi

# Empty shipped file: process must refuse to start (exit 2) with both knobs named.
clear_product_env
set +e
env -u SENTINEL_ADDR -u REDIS_ADDRS -u MASTER_NAME -u APPLY \
  -u RSR_SENTINEL_ADDR -u RSR_REDIS_ADDRS -u RSR_MASTER_NAME -u RSR_APPLY \
  /usr/bin/reconciler --config /etc/default/redis-sentinel-reconciler --once \
  >/tmp/rsr-p01-empty.out 2>/tmp/rsr-p01-empty.err
empty_rc=$?
set -e
cat /tmp/rsr-p01-empty.err | tee -a "$LOG"
[[ "$empty_rc" -eq 2 ]] || fail "empty config exit $empty_rc, want 2"
for want in "missing required settings" SENTINEL_ADDR REDIS_ADDRS "can become master" "this host"; do
  grep -q "$want" /tmp/rsr-p01-empty.err || fail "empty-config stderr missing: $want"
done
# Both were empty, so both blocks should appear.
grep -q 'SENTINEL_ADDR  (--sentinel-addr' /tmp/rsr-p01-empty.err || fail "missing SENTINEL_ADDR help block"
grep -q 'REDIS_ADDRS  (--redis-addrs' /tmp/rsr-p01-empty.err || fail "missing REDIS_ADDRS help block"

systemctl start redis-sentinel-reconciler >/dev/null 2>&1 || true
sleep 2
active="$(systemctl is-active redis-sentinel-reconciler 2>/dev/null || true)"
[[ "$active" != "active" ]] || fail "unit became active with empty SENTINEL_ADDR/REDIS_ADDRS (is-active=$active)"
journalctl -u redis-sentinel-reconciler -n 80 --no-pager > /tmp/rsr-p01-journal-empty.txt 2>/dev/null || true
grep -q "missing required settings" /tmp/rsr-p01-journal-empty.txt \
  || fail "journalctl after empty start missing the required-settings error"

systemctl stop redis-sentinel-reconciler 2>/dev/null || true
systemctl reset-failed redis-sentinel-reconciler 2>/dev/null || true

sed -i "s|^SENTINEL_ADDR=.*|SENTINEL_ADDR=${FILL_SENTINEL}|" /etc/default/redis-sentinel-reconciler
sed -i "s|^REDIS_ADDRS=.*|REDIS_ADDRS=${FILL_REDIS}|" /etc/default/redis-sentinel-reconciler
sed -i "s|^MASTER_NAME=.*|MASTER_NAME=${FILL_MASTER}|" /etc/default/redis-sentinel-reconciler
# Keep APPLY=false (shipped default).

clear_product_env
set +e
env -u SENTINEL_ADDR -u REDIS_ADDRS -u MASTER_NAME -u APPLY \
  -u RSR_SENTINEL_ADDR -u RSR_REDIS_ADDRS -u RSR_MASTER_NAME -u RSR_APPLY \
  /usr/bin/reconciler --config /etc/default/redis-sentinel-reconciler --once \
  >/tmp/rsr-p01-once.out 2>/tmp/rsr-p01-once.err
once_rc=$?
set -e
cat /tmp/rsr-p01-once.out /tmp/rsr-p01-once.err | tee -a "$LOG"
[[ "$once_rc" -eq 0 ]] || fail "filled config --once exit $once_rc"
grep -q 'reconciler started' /tmp/rsr-p01-once.out || fail "filled --once did not log reconciler started"
grep -q '"apply":false' /tmp/rsr-p01-once.out || fail "filled --once should stay dry-run (APPLY=false)"

systemctl enable --now redis-sentinel-reconciler
sleep 2
active="$(systemctl is-active redis-sentinel-reconciler)"
[[ "$active" == "active" ]] || fail "unit not active after filling addresses (is-active=$active)"
journalctl -u redis-sentinel-reconciler -n 40 --no-pager > /tmp/rsr-p01-journal-up.txt 2>/dev/null || true
grep -q 'reconciler started' /tmp/rsr-p01-journal-up.txt \
  || fail "journal after enable --now missing reconciler started"

log "PASS dpkg install + empty fail + filled start"
exit 0
