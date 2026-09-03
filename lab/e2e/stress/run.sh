#!/usr/bin/env bash
# Short L1 stress: flap ads / dual refuse / parallel apply storm.
# Not a multi-hour soak - wall target ~3-8 min with warm lab.
set -euo pipefail
E2E_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib.sh
source "$E2E_DIR/lib.sh"

cd "$LAB_DIR"
STRESS_ROUNDS="${STRESS_ROUNDS:-8}"

log "=== stress suite (short L1) rounds=$STRESS_ROUNDS ==="
log "canon: docs/operations.md"

ensure_lab_up || { log "FATAL: lab not ready"; exit 1; }

run_case() {
  local script="$1"
  set +e
  # shellcheck disable=SC1090
  source "$script"
  set +e
}

for f in "$E2E_DIR"/stress/S*.sh; do
  [[ -f "$f" ]] || continue
  restore_steady_state || true
  run_case "$f"
done

restore_steady_state || true
print_summary
rc=$?
log "stress suite done pass=$PASS fail=$FAIL skip=$SKIP"
exit $rc
