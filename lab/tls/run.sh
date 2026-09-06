#!/usr/bin/env bash
# TLS lab: Redis + Sentinel tls-port only; reconciler --tls --apply heals a fake MONITOR.
set -euo pipefail

TLS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$TLS_DIR/../.." && pwd)"
COMPOSE=(docker compose -f "$TLS_DIR/docker-compose.yml")
MASTER_NAME="${MASTER_NAME:-mymaster}"
FAKE="${FAKE_MASTER_IP:-10.255.255.254}"
ART="${TLS_ART:-$ROOT/lab/e2e/artifacts/tls_$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$ART"

log() { printf '[tls] %s\n' "$*"; }
fail() { log "FAIL: $*"; "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true; exit 1; }

chmod +x "$TLS_DIR/gen-certs.sh" "$TLS_DIR/sentinel-entrypoint.sh"
"$TLS_DIR/gen-certs.sh"

log "compose up"
"${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
"${COMPOSE[@]}" up -d --build redis
for _ in $(seq 1 30); do
  "${COMPOSE[@]}" exec -T redis redis-cli --tls --cacert /tls/ca.pem -h redis.lab PING 2>/dev/null | grep -q PONG && break
  sleep 1
done
tls_cli() {
  "${COMPOSE[@]}" exec -T redis redis-cli --tls --cacert /tls/ca.pem -h redis.lab "$@"
}
pong="$(tls_cli PING | tr -d '\r' || true)"
[[ "$pong" == "PONG" ]] || fail "Redis TLS PING got $pong"

"${COMPOSE[@]}" up -d sentinel
sleep 3
if ! docker inspect -f '{{.State.Running}}' "$("${COMPOSE[@]}" ps -q sentinel)" 2>/dev/null | grep -q true; then
  "${COMPOSE[@]}" logs sentinel | tee "$ART/sentinel.log" >/dev/null
  fail "sentinel not running. log=$ART/sentinel.log"
fi
sentinel_cli() {
  "${COMPOSE[@]}" exec -T sentinel redis-cli --tls --cacert /tls/ca.pem -h sentinel.lab -p 26379 "$@"
}

ad="$(sentinel_cli SENTINEL get-master-addr-by-name "$MASTER_NAME" | head -1 | tr -d '\r')"
[[ -n "$ad" && "$ad" != "(nil)" ]] || fail "empty sentinel ad"
rip="$(${COMPOSE[@]} exec -T redis hostname -i | awk '{print $1}')"
log "ad=$ad redis_ip=$rip"

# Sticky lie: MONITOR unreachable IP (Hello cannot rewrite with one Sentinel).
sentinel_cli SENTINEL REMOVE "$MASTER_NAME" >/dev/null 2>&1 || true
sentinel_cli SENTINEL MONITOR "$MASTER_NAME" "$FAKE" 6379 1 >/dev/null
lie="$(sentinel_cli SENTINEL get-master-addr-by-name "$MASTER_NAME" | head -1 | tr -d '\r')"
[[ "$lie" == "$FAKE" ]] || fail "lie did not stick ad=$lie"

log "reconciler --tls --apply --once"
out="$("${COMPOSE[@]}" run --rm --no-deps --entrypoint reconciler reconciler \
  --sentinel-addr=sentinel.lab:26379 \
  --master-name="$MASTER_NAME" \
  --redis-addrs=redis.lab:6379 \
  --local-sentinel --apply --quorum=1 --once --heal-cooldown=0 \
  --tls --tls-ca-file=/tls/ca.pem 2>&1)" || true
printf '%s\n' "$out" | tee "$ART/apply.log" >/dev/null

echo "$out" | grep -q 'heal succeeded' || fail "no heal succeeded. log=$ART/apply.log"
after="$(sentinel_cli SENTINEL get-master-addr-by-name "$MASTER_NAME" | head -1 | tr -d '\r')"
[[ "$after" != "$FAKE" ]] || fail "ads still fake $FAKE"
[[ "$after" == "$rip" || "$after" == "redis.lab" || "$after" == "172.30.90.10" ]] || fail "ads $after not redis ($rip / redis.lab)"
echo "$out" | grep -qi REPLICAOF && fail "reconciler must not REPLICAOF"

log "PASS tls e2e: --tls --apply healed $FAKE -> $after art=$ART"
"${COMPOSE[@]}" down -v --remove-orphans >/dev/null
printf 'PASS tls e2e ad=%s art=%s\n' "$after" "$ART"
