#!/usr/bin/env bash
# Kind smoke + chaos + stress. Idempotent cluster bring-up once.
set -euo pipefail
KIND_DIR="$(cd "$(dirname "$0")" && pwd)"
"$KIND_DIR/run.sh"
export KIND_SKIP_UP=1
"$KIND_DIR/e2e.sh"
"$KIND_DIR/chaos.sh"
"$KIND_DIR/stress.sh"
printf 'PASS kind-test (e2e + chaos + stress)\n'
