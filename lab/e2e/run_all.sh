#!/usr/bin/env bash
# Full lab e2e: smoke (T01-T07) + SPEC §5 matrix A-G on 5 Redis + 5 Sentinel.
set -euo pipefail
E2E_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$E2E_DIR/lib.sh"

cd "$LAB_DIR"

SUITE="${E2E_SUITE:-all}" # all | smoke | matrix

log "=== redis-sentinel-reconciler lab e2e (suite=$SUITE) ==="
log "SPEC: docs/docs/architecture/redis-sentinel-reconciler.md"
log "Topology: 5 Redis + 5 Sentinel (quorum=$QUORUM)"

if [[ "$SUITE" == "hazards" ]]; then
  exec "$E2E_DIR/hazards/run.sh"
fi

ensure_lab_up || { log "FATAL: lab not ready"; exit 1; }

run_case() {
  local script="$1"
  set +e
  # shellcheck disable=SC1090
  source "$script"
  set +e
}

run_smoke() {
  run_case "$E2E_DIR/01_steady.sh"
  run_case "$E2E_DIR/02_kill_master.sh"
  run_case "$E2E_DIR/04_rejoin_demote.sh"
  restore_steady_state || true
  run_case "$E2E_DIR/03_kill_sentinel.sh"
  restore_steady_state || true
  run_case "$E2E_DIR/05_dual_master.sh"
  restore_steady_state || true
  run_case "$E2E_DIR/06_diverge_dryrun.sh"
  restore_steady_state || true
  run_case "$E2E_DIR/07_api_heal_node1.sh"
  restore_steady_state || true
}

run_matrix() {
  local f
  for f in "$E2E_DIR"/matrix/*.sh; do
    [[ -f "$f" ]] || continue
    restore_steady_state || true
    run_case "$f"
  done
}

case "$SUITE" in
  smoke)  run_smoke ;;
  matrix) run_matrix ;;
  all)
    run_smoke
    run_matrix
    ;;
  *)
    log "Unknown E2E_SUITE=$SUITE (use all|smoke|matrix|hazards)"; exit 2 ;;
esac

restore_steady_state || true
T01_LABEL="T01 final" T01_REFRESH_LOGS=1 run_case "$E2E_DIR/01_steady.sh"

print_summary
rc=$?
log "done pass=$PASS fail=$FAIL skip=$SKIP"
exit $rc
