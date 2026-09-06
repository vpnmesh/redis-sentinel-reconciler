#!/usr/bin/env bash
# Print reconciler /metrics gauges an operator should watch with --apply on.
# Usage: scripts/dwell-status.sh [http://127.0.0.1:9123/metrics]
set -euo pipefail
URL="${1:-http://127.0.0.1:9123/metrics}"
body="$(curl -fsS --max-time 5 "$URL")" || {
  printf 'FAIL scrape %s\n' "$URL" >&2
  exit 1
}

pick() {
  echo "$body" | awk -v n="$1" '$1==n || index($1, n "{")==1 {print $2; exit}'
}

printf 'url=%s\n' "$URL"
printf 'diverged=%s writable_masters=%s would_heal=%s\n' \
  "$(pick redis_sentinel_reconciler_diverged)" \
  "$(pick redis_sentinel_reconciler_writable_masters)" \
  "$(pick redis_sentinel_reconciler_would_heal)"
printf 'diverge_total=%s heal_fail_total=%s alert_dual_master_total=%s apply_refused_total=%s\n' \
  "$(pick redis_sentinel_reconciler_diverge_total)" \
  "$(pick redis_sentinel_reconciler_heal_fail_total)" \
  "$(pick redis_sentinel_reconciler_alert_dual_master_total)" \
  "$(pick redis_sentinel_reconciler_apply_refused_total)"
