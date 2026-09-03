#!/usr/bin/env bash
# Hazard e2e: for each HAZARD-CASES H*:
#   PHASE A - naive apply (raw Sentinel API / unsafe flags) -> prove outage / cement
#   PHASE B - reconciler with countermeasures -> refuse or safe path
set -euo pipefail
E2E_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib.sh
source "$E2E_DIR/lib.sh"

cd "$LAB_DIR"

log "=== hazard suite (apply-worsens -> countermeasure) ==="
log "canon: docs/operations.md"

ensure_lab_up || { log "FATAL: lab not ready"; exit 1; }

run_case() {
  local script="$1"
  set +e
  # shellcheck disable=SC1090
  source "$script"
  set +e
}

for f in "$E2E_DIR"/hazards/H*.sh; do
  [[ -f "$f" ]] || continue
  restore_steady_state || true
  run_case "$f"
done

restore_steady_state || true
print_summary
rc=$?
log "hazard suite done pass=$PASS fail=$FAIL skip=$SKIP"
exit $rc
