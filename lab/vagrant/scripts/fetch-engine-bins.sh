#!/usr/bin/env bash
# Fetch Valkey (or Redis) server/cli bins from official images into lab/vagrant/bins/<engine>/.
set -euo pipefail
ENGINE="${ENGINE:-valkey}"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="$ROOT/lab/vagrant/bins/$ENGINE"
mkdir -p "$OUT"

case "$ENGINE" in
  valkey)
    IMG="${VALKEY_IMAGE:-valkey/valkey:8}"
    TMP="rsr-fetch-${ENGINE}-$$"
    docker pull "$IMG"
    docker create --name "$TMP" "$IMG" >/dev/null
    # Layout varies by tag; probe common paths.
    for b in valkey-server redis-server; do
      if docker cp "$TMP:/usr/local/bin/$b" "$OUT/valkey-server" 2>/dev/null \
        || docker cp "$TMP:/usr/bin/$b" "$OUT/valkey-server" 2>/dev/null; then
        break
      fi
    done
    for b in valkey-cli redis-cli; do
      if docker cp "$TMP:/usr/local/bin/$b" "$OUT/valkey-cli" 2>/dev/null \
        || docker cp "$TMP:/usr/bin/$b" "$OUT/valkey-cli" 2>/dev/null; then
        break
      fi
    done
    docker rm -f "$TMP" >/dev/null
    chmod +x "$OUT/valkey-server" "$OUT/valkey-cli"
    ls -la "$OUT"
    ;;
  redis)
    echo "redis uses apt inside nodes; bins fetch not required"
    ;;
  *)
    echo "ENGINE must be redis|valkey"; exit 2
    ;;
esac
