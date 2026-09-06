#!/usr/bin/env bash
# Shared Kind lab helpers. Callers set -euo pipefail and source this file.
# shellcheck disable=SC2034

KIND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$KIND_DIR/../.." && pwd)"
CLUSTER="${KIND_CLUSTER:-rsr}"
NS="${KIND_NS:-rsr}"
REDIS_RELEASE="${REDIS_RELEASE:-redis}"
RSR_RELEASE="${RSR_RELEASE:-rsr}"
PASS="${REDIS_PASSWORD:-lab-rsr-kind}"
MASTER_NAME="${MASTER_NAME:-mymaster}"
FAKE_MASTER="${FAKE_MASTER:-10.255.255.254}"
ART="${ART:-}"

kind_log() { printf '[kind] %s\n' "$*"; }
kind_fail() { kind_log "FAIL: $*"; exit 1; }

kind_use_context() {
  kubectl config use-context "kind-${CLUSTER}" >/dev/null
}

kind_art() {
  local name="$1"
  ART="${KIND_ART:-$ROOT/lab/kind/artifacts/${name}_$(date -u +%Y%m%dT%H%M%SZ)}"
  mkdir -p "$ART"
}

kind_ensure_up() {
  if [[ "${KIND_SKIP_UP:-0}" != "1" ]]; then
    "$KIND_DIR/run.sh"
  fi
  kind_use_context
}

redis_pod() { printf '%s-node-%s' "$REDIS_RELEASE" "$1"; }

sentinel_cli() {
  local pod="$1"; shift
  kubectl -n "$NS" exec "$pod" -c sentinel -- \
    redis-cli -p 26379 -a "$PASS" --no-auth-warning "$@"
}

redis_cli() {
  local pod="$1"; shift
  kubectl -n "$NS" exec "$pod" -c redis -- \
    redis-cli -a "$PASS" --no-auth-warning "$@"
}

sentinel_ad_host() {
  sentinel_cli "$(redis_pod "$1")" SENTINEL get-master-addr-by-name "$MASTER_NAME" \
    | tr -d '\r' | awk 'NR==1{print; exit}'
}

pod_ip() {
  kubectl -n "$NS" get pod "$1" -o jsonpath='{.status.podIP}'
}

redis_role() {
  redis_cli "$(redis_pod "$1")" ROLE | tr -d '\r' | awk 'NR==1{print; exit}'
}

writable_idx() {
  local i
  for i in 0 1 2; do
    if [[ "$(redis_role "$i")" == "master" ]]; then
      if redis_cli "$(redis_pod "$i")" SET "rsr:kind:w:${i}" 1 EX 15 >/dev/null 2>&1; then
        printf '%s\n' "$i"
        return 0
      fi
    fi
  done
  return 1
}

replica_idx() {
  local w i
  w="$(writable_idx)" || return 1
  for i in 0 1 2; do
    if [[ "$i" != "$w" ]]; then
      printf '%s\n' "$i"
      return 0
    fi
  done
  return 1
}

writable_count() {
  local n=0 i
  for i in 0 1 2; do
    [[ "$(redis_role "$i")" == "master" ]] || continue
    if redis_cli "$(redis_pod "$i")" SET "rsr:kind:wc:${i}" 1 EX 15 >/dev/null 2>&1; then
      n=$((n + 1))
    fi
  done
  printf '%s\n' "$n"
}

writer_set_ok() {
  local w
  w="$(writable_idx)" || return 1
  redis_cli "$(redis_pod "$w")" SET "rsr:kind:writer" ok EX 30 >/dev/null 2>&1
}

wait_sts3() {
  kubectl -n "$NS" wait --for=jsonpath='{.status.readyReplicas}'=3 "sts/${1}" --timeout=180s
}

point_sentinel() {
  local pod="$1" ip="$2"
  sentinel_cli "$pod" SENTINEL REMOVE "$MASTER_NAME" >/dev/null 2>&1 || true
  sentinel_cli "$pod" SENTINEL MONITOR "$MASTER_NAME" "$ip" 6379 2 >/dev/null
  sentinel_cli "$pod" SENTINEL SET "$MASTER_NAME" auth-pass "$PASS" >/dev/null
}

lie_all_fake() {
  local i
  for i in 0 1 2; do
    point_sentinel "$(redis_pod "$i")" "$FAKE_MASTER"
  done
}

ads_all_fake() {
  local i ad
  for i in 0 1 2; do
    ad="$(sentinel_ad_host "$i")"
    [[ "$ad" == "$FAKE_MASTER" ]] || return 1
  done
  return 0
}

ad_is_writable() {
  local ad="$1" idx="$2"
  local ip short
  ip="$(pod_ip "$(redis_pod "$idx")")"
  short="redis-node-${idx}"
  [[ "$ad" == "$ip" || "$ad" == "$short" || "$ad" == *"${short}."* ]]
}

ads_match_writable() {
  local w i ad
  w="$(writable_idx)" || return 1
  for i in 0 1 2; do
    ad="$(sentinel_ad_host "$i")"
    ad_is_writable "$ad" "$w" || return 1
  done
  return 0
}

helm_rsr() {
  local wait_flags=(--wait --timeout 5m)
  if [[ "${1:-}" == "--no-wait" ]]; then
    shift
    wait_flags=()
  fi
  helm upgrade --install "$RSR_RELEASE" "$ROOT/deploy/helm/redis-sentinel-reconciler" \
    --namespace "$NS" \
    -f "$KIND_DIR/values-rsr.yaml" \
    "$@" \
    "${wait_flags[@]}" >/dev/null
}

rsr_apply() {
  helm_rsr --set apply=true --set healCooldown=5s
  wait_sts3 "$RSR_RELEASE"
}

# Kill-switch helper (not used by kind-e2e/chaos/stress). Lab default is --apply.
rsr_dryrun() {
  helm_rsr --set apply=false
  wait_sts3 "$RSR_RELEASE"
}

scale_rsr() {
  kubectl -n "$NS" scale "sts/${RSR_RELEASE}" --replicas="$1" >/dev/null
  if [[ "$1" == "0" ]]; then
    kubectl -n "$NS" wait --for=delete pod -l app=redis-sentinel-reconciler --timeout=60s >/dev/null || true
  else
    wait_sts3 "$RSR_RELEASE"
  fi
}

dump_rsr_logs() {
  local prefix="$1" i
  for i in 0 1 2; do
    kubectl -n "$NS" logs "${RSR_RELEASE}-${i}" -c reconciler --tail=250 \
      >"${ART}/${prefix}-rsr-${i}.log" 2>/dev/null || true
  done
}

rsr_logs() {
  local i
  for i in 0 1 2; do
    kubectl -n "$NS" logs "${RSR_RELEASE}-${i}" -c reconciler --tail="${1:-200}" 2>/dev/null || true
  done
}

rsr_logs_since() {
  local since="$1" i
  for i in 0 1 2; do
    kubectl -n "$NS" logs "${RSR_RELEASE}-${i}" -c reconciler --since-time="$since" 2>/dev/null || true
  done
}

wait_until() {
  local desc="$1" timeout_s="$2"
  shift 2
  local t=0
  while (( t < timeout_s )); do
    if "$@"; then
      return 0
    fi
    sleep 2
    t=$((t + 2))
  done
  kind_log "timeout waiting: $desc (${timeout_s}s)"
  return 1
}

restore_ads_to_writable() {
  local w ip i
  w="$(writable_idx)" || return 1
  ip="$(pod_ip "$(redis_pod "$w")")"
  [[ -n "$ip" ]] || return 1
  for i in 0 1 2; do
    point_sentinel "$(redis_pod "$i")" "$ip" || true
  done
}

demote_to() {
  local master_idx="$1" i mip
  mip="$(pod_ip "$(redis_pod "$master_idx")")"
  for i in 0 1 2; do
    [[ "$i" == "$master_idx" ]] && continue
    if [[ "$(redis_role "$i")" == "master" ]]; then
      redis_cli "$(redis_pod "$i")" REPLICAOF "$mip" 6379 >/dev/null || true
    fi
  done
}
