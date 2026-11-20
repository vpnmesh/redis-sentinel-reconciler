#!/usr/bin/env bash
# S5: SENTINEL MONITOR receives the --redis-addrs hostname, not the pod IP.
#
# S1–S4 cannot show this. redis_seed_addrs() is container IPs, and those cases
# assert get-master-addr-by-name equals that IP. lab/scripts/sentinel-entrypoint.sh
# rewrites the template hostname to an IPv4, and lab/config/sentinel-*.conf does
# not set resolve-hostnames or announce-hostnames. Redis 7 then rejects
# `SENTINEL MONITOR <hostname>` with "Invalid IP address or hostname specified".
#
# This case starts a throwaway Sentinel (those two flags on, its own master
# name) so a heal can be read back. sentinel-1..5 are not reconfigured.
set -uo pipefail
set +e
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

log "S5: MONITOR host is the seed hostname (pod IP listed first)"

msvc=$(current_master_svc) || { bad "S5" "no master"; return 0; }
mip=$(svc_ip "$msvc")
[[ -n "$mip" ]] || { bad "S5" "no ip for $msvc"; return 0; }

NAME=rsr-s5-sentinel
MASTER=rsrhn
CONF="$(mktemp)"
LOG="$ART_DIR/stress-s5-hostname.log"
cleanup() {
  trap - RETURN
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  rm -f "$CONF"
}
trap cleanup RETURN

cat >"$CONF" <<EOF
port 26379
bind 0.0.0.0
protected-mode no
dir /data
sentinel resolve-hostnames yes
sentinel announce-hostnames yes
sentinel monitor ${MASTER} ${mip} 6379 1
sentinel down-after-milliseconds ${MASTER} 60000
sentinel failover-timeout ${MASTER} 180000
sentinel parallel-syncs ${MASTER} 1
EOF

docker rm -f "$NAME" >/dev/null 2>&1 || true
if ! docker run -d --name "$NAME" --network "$LAB_NET" \
  --add-host "${msvc}:${mip}" \
  -v "$CONF":/usr/local/etc/sentinel.conf:ro \
  redis:7-alpine \
  sh -c 'cp /usr/local/etc/sentinel.conf /data/sentinel.conf && exec redis-sentinel /data/sentinel.conf' \
  >/dev/null; then
  bad "S5" "ephemeral sentinel did not start"
  return 0
fi

ready=0
for _ in $(seq 1 25); do
  if docker exec "$NAME" redis-cli -p 26379 PING 2>/dev/null | tr -d '\r' | grep -q PONG; then
    ready=1
    break
  fi
  sleep 0.2
done
if (( ready == 0 )); then
  bad "S5" "ephemeral sentinel did not PING"
  return 0
fi

# IP of the writable node first, then every service hostname. A LookupIP or
# first-match bug writes the IP. The hostname must still be the MONITOR host.
seeds="${mip}:6379"
for svc in "${REDIS_SVCS[@]}"; do
  seeds+=",${svc}:6379"
done

image=$(docker inspect -f '{{.Config.Image}}' "$(svc_cid reconciler-1)" 2>/dev/null || true)
[[ -n "$image" ]] || image="lab-reconciler-1"

if ! docker run --rm --network "$LAB_NET" \
  --add-host "${msvc}:${mip}" \
  --entrypoint /usr/local/bin/reconciler \
  "$image" \
  --sentinel-addr="${NAME}:26379" \
  --master-name="$MASTER" \
  --local-sentinel \
  --quorum=1 \
  --heal-cooldown=0 \
  --heal-lease=false \
  --redis-addrs="$seeds" \
  --once --apply >"$LOG" 2>&1; then
  log "S5 reconciler exit nonzero (see $LOG)"
fi

ad=$(docker exec "$NAME" redis-cli -p 26379 SENTINEL get-master-addr-by-name "$MASTER" 2>/dev/null | head -1 | tr -d '\r')
mon_line=$(docker exec "$NAME" grep -E '^sentinel monitor ' /data/sentinel.conf 2>/dev/null | tr -d '\r' || true)
want_conf="sentinel monitor ${MASTER} ${msvc} 6379 1"

if [[ "$ad" != "$msvc" ]]; then
  bad "S5" "ad=$ad want=$msvc (ip $mip was first seed). conf=$mon_line log=$(tail -3 "$LOG" | tr '\n' '|')"
  return 0
fi
if [[ "$mon_line" != "$want_conf" ]]; then
  bad "S5" "sentinel.conf has [$mon_line] want [$want_conf]"
  return 0
fi
if ! grep -q "\"action\":\"SENTINEL REMOVE+MONITOR\"" "$LOG" || ! grep -q "\"host\":\"${msvc}\"" "$LOG"; then
  bad "S5" "log missing MONITOR host ${msvc} (log=$LOG)"
  return 0
fi
if grep -q "\"host\":\"${mip}\"" "$LOG"; then
  bad "S5" "MONITOR host was the pod IP ${mip} (log=$LOG)"
  return 0
fi
if ! grep -q 'heal succeeded' "$LOG"; then
  bad "S5" "hostname was stored but verify did not pass (log=$LOG)"
  return 0
fi

ok "S5 MONITOR ${msvc} (seed IP ${mip} listed first); ad=${ad}"
