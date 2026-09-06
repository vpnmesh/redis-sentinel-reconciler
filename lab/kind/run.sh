#!/usr/bin/env bash
# Create (or reuse) Kind cluster rsr, build a local image, install Bitnami Redis
# (3 pods + Sentinel) and our chart as a 3-pod StatefulSet.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
KIND_DIR="$ROOT/lab/kind"
CLUSTER="${KIND_CLUSTER:-rsr}"
NS="${KIND_NS:-rsr}"
IMAGE="${KIND_IMAGE:-redis-sentinel-reconciler:local}"
BITNAMI_CHART="${BITNAMI_CHART:-oci://registry-1.docker.io/bitnamicharts/redis}"
BITNAMI_CHART_VERSION="${BITNAMI_CHART_VERSION:-25.5.3}"
REDIS_RELEASE="${REDIS_RELEASE:-redis}"
RSR_RELEASE="${RSR_RELEASE:-rsr}"
REDIS_IMAGE="${REDIS_IMAGE:-docker.io/bitnamilegacy/redis:8.2.1-debian-12-r0}"
SENTINEL_IMAGE="${SENTINEL_IMAGE:-docker.io/bitnamilegacy/redis-sentinel:8.2.1-debian-12-r0}"

log() { printf '[kind] %s\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || { log "FATAL: need $1 on PATH"; exit 1; }; }

need kind
need kubectl
need helm
need docker

if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  log "create cluster $CLUSTER"
  kind create cluster --config "$KIND_DIR/cluster.yaml"
else
  log "reuse cluster $CLUSTER"
fi
kubectl cluster-info --context "kind-${CLUSTER}" >/dev/null

log "build $IMAGE"
tag="$(git -C "$ROOT" describe --tags --exact-match 2>/dev/null || true)"
if [ -n "$tag" ]; then
  ver="${tag#v}"
else
  ver=dev
fi
rev="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
docker build \
  --build-arg VERSION="$ver" \
  --build-arg REVISION="$rev" \
  --build-arg VCS_TAG="$tag" \
  -t "$IMAGE" "$ROOT"
kind load docker-image "$IMAGE" --name "$CLUSTER"

log "pull/load Redis images (bitnamilegacy, not published BSI)"
docker pull "$REDIS_IMAGE"
docker pull "$SENTINEL_IMAGE"
kind load docker-image "$REDIS_IMAGE" --name "$CLUSTER"
kind load docker-image "$SENTINEL_IMAGE" --name "$CLUSTER"

kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"

log "helm template our chart (StatefulSet)"
helm template "$RSR_RELEASE" "$ROOT/deploy/helm/redis-sentinel-reconciler" \
  -n "$NS" -f "$KIND_DIR/values-rsr.yaml" | tee /tmp/rsr-kind-template.yaml | grep -q 'kind: StatefulSet'

if helm -n "$NS" status "$REDIS_RELEASE" >/dev/null 2>&1; then
  cur="$(helm -n "$NS" list -f "^${REDIS_RELEASE}$" --output json \
    | python3 -c 'import json,sys; r=json.load(sys.stdin); print(r[0]["chart"] if r else "")')"
  want="redis-${BITNAMI_CHART_VERSION}"
  if [[ "$cur" != "$want" ]]; then
    log "replace $REDIS_RELEASE ($cur -> $want)"
    helm uninstall "$REDIS_RELEASE" -n "$NS" --wait --timeout 3m || true
  fi
fi

log "helm $REDIS_RELEASE $BITNAMI_CHART $BITNAMI_CHART_VERSION"
helm upgrade --install "$REDIS_RELEASE" "$BITNAMI_CHART" \
  --version "$BITNAMI_CHART_VERSION" \
  --namespace "$NS" \
  -f "$KIND_DIR/values-redis.yaml" \
  --wait --timeout 10m

log "helm $RSR_RELEASE (local chart)"
helm upgrade --install "$RSR_RELEASE" "$ROOT/deploy/helm/redis-sentinel-reconciler" \
  --namespace "$NS" \
  -f "$KIND_DIR/values-rsr.yaml" \
  --wait --timeout 5m

log "wait readyReplicas=3"
kubectl -n "$NS" wait --for=jsonpath='{.status.readyReplicas}'=3 \
  "sts/${REDIS_RELEASE}-node" --timeout=180s
# Restart our STS after Redis DNS exists (helm upgrade is a no-op if values
# did not change, and old pods keep pre-Redis-reinstall logs).
log "rollout restart $RSR_RELEASE"
kubectl -n "$NS" rollout restart "sts/${RSR_RELEASE}" >/dev/null
kubectl -n "$NS" rollout status "sts/${RSR_RELEASE}" --timeout=2m >/dev/null
kubectl -n "$NS" wait --for=jsonpath='{.status.readyReplicas}'=3 \
  "sts/${RSR_RELEASE}" --timeout=180s

log "cluster is up (namespace $NS). smoke + lie: make kind-e2e"
