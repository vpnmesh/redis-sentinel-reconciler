#!/usr/bin/env bash
set -euo pipefail
CLUSTER="${KIND_CLUSTER:-rsr}"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  kind delete cluster --name "$CLUSTER"
else
  echo "cluster $CLUSTER is not running"
fi
