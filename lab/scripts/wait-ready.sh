#!/usr/bin/env bash
set -euo pipefail

COMPOSE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$COMPOSE_DIR"

MAX_WAIT="${MAX_WAIT:-120}"
INTERVAL="${INTERVAL:-2}"
elapsed=0
FAKE_PREFIX="${FAKE_MASTER_IP:-10.255.255.254}"

echo "Waiting for Sentinel to report master for 'mymaster' (max ${MAX_WAIT}s)..."

while (( elapsed < MAX_WAIT )); do
  if out=$(docker compose exec -T sentinel-1 redis-cli -p 26379 SENTINEL get-master-addr-by-name mymaster 2>/dev/null); then
    host=$(printf '%s\n' "$out" | head -1 | tr -d '\r')
    if [[ -n "$host" && "$host" != "(nil)" && "$host" != "$FAKE_PREFIX" ]]; then
      echo "Master address:"
      echo "$out"
      exit 0
    fi
  fi
  sleep "$INTERVAL"
  elapsed=$((elapsed + INTERVAL))
done

echo "ERROR: timed out waiting for SENTINEL get-master-addr-by-name mymaster" >&2
exit 1
