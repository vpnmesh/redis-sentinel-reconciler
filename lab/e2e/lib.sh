#!/usr/bin/env bash
# Shared helpers for redis-sentinel-reconciler lab e2e (5 Redis + 5 Sentinel).
# shellcheck disable=SC2034
set -euo pipefail

if [[ -n "${_RSR_E2E_LIB:-}" ]]; then
  return 0
fi
_RSR_E2E_LIB=1

E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "$E2E_DIR/.." && pwd)"
ROOT_DIR="$(cd "$LAB_DIR/.." && pwd)"
COMPOSE=(docker compose -f "$LAB_DIR/docker-compose.yml")
MASTER_NAME="${MASTER_NAME:-mymaster}"
QUORUM="${QUORUM:-3}"
FAKE_MASTER_IP="${FAKE_MASTER_IP:-10.255.255.254}"
ART_DIR="${ART_DIR:-$ROOT_DIR/lab/e2e/artifacts}"
mkdir -p "$ART_DIR"

RECONCILER_SVCS=(reconciler-1 reconciler-2 reconciler-3 reconciler-4 reconciler-5)
REDIS_SVCS=(redis-1 redis-2 redis-3 redis-4 redis-5)
SENTINEL_SVCS=(sentinel-1 sentinel-2 sentinel-3 sentinel-4 sentinel-5)
LAB_NET="${LAB_NET:-redis-sentinel-lab}"

PASS=0
FAIL=0
SKIP=0
RESULTS=()

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
ok()  { PASS=$((PASS+1)); RESULTS+=("PASS|$1"); log "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); RESULTS+=("FAIL|$1|$2"); log "FAIL: $1 - $2"; }
skip(){ SKIP=$((SKIP+1)); RESULTS+=("SKIP|$1|$2"); log "SKIP: $1 - $2"; }

compose() { "${COMPOSE[@]}" "$@"; }

svc_cid() { compose ps -aq "$1"; }

svc_ip() {
  local cid
  cid=$(svc_cid "$1")
  docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$cid"
}

ip_to_redis_svc() {
  local want="$1" svc tip
  for svc in "${REDIS_SVCS[@]}"; do
    tip=$(svc_ip "$svc" 2>/dev/null || true)
    if [[ "$tip" == "$want" ]]; then
      echo "$svc"
      return 0
    fi
  done
  return 1
}

sentinel_master_host() {
  local s="${1:-sentinel-1}"
  compose exec -T "$s" redis-cli -p 26379 SENTINEL get-master-addr-by-name "$MASTER_NAME" 2>/dev/null | head -1 | tr -d '\r'
}

sentinel_master_port() {
  local s="${1:-sentinel-1}"
  compose exec -T "$s" redis-cli -p 26379 SENTINEL get-master-addr-by-name "$MASTER_NAME" 2>/dev/null | tail -1 | tr -d '\r'
}

redis_role() {
  compose exec -T "$1" redis-cli INFO replication 2>/dev/null | tr -d '\r' | awk -F: '/^role:/{print $2}'
}

redis_master_host() {
  compose exec -T "$1" redis-cli INFO replication 2>/dev/null | tr -d '\r' | awk -F: '/^master_host:/{print $2}'
}

svc_running() {
  local cid
  cid=$(svc_cid "$1" 2>/dev/null || true)
  [[ -n "$cid" ]] || return 1
  [[ "$(docker inspect -f '{{.State.Running}}' "$cid")" == "true" ]]
}

writable_count() {
  local n=0 svc
  for svc in "${REDIS_SVCS[@]}"; do
    svc_running "$svc" || continue
    [[ "$(redis_role "$svc")" == "master" ]] || continue
    if compose exec -T "$svc" redis-cli SET "e2e:probe:$$" 1 EX 5 >/dev/null 2>&1; then
      n=$((n+1))
    fi
  done
  echo "$n"
}

writer_set_ok() {
  local host port client s
  host=""
  for s in "${SENTINEL_SVCS[@]}"; do
    svc_running "$s" || continue
    host=$(sentinel_master_host "$s" 2>/dev/null || true)
    [[ -n "$host" && "$host" != "(nil)" ]] && break
  done
  port=$(sentinel_master_port sentinel-1 2>/dev/null || true)
  [[ -n "$host" && "$host" != "(nil)" ]] || return 1
  for client in "${REDIS_SVCS[@]}"; do
    svc_running "$client" || continue
    if compose exec -T "$client" redis-cli -h "$host" -p "${port:-6379}" SET "e2e:writer:$(date +%s)" ok EX 30 >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

wait_until() {
  local desc="$1" timeout="$2"
  shift 2
  local elapsed=0
  while (( elapsed < timeout )); do
    if "$@"; then
      return 0
    fi
    sleep 2
    elapsed=$((elapsed+2))
  done
  log "timeout after ${timeout}s waiting for: $desc"
  return 1
}

single_writable() {
  [[ "$(writable_count)" == "1" ]]
}

# Fix Redis roles only (do not touch Sentinel ads). Used when ads must stay lied for heal tests.
ensure_unique_writable_redis() {
  local svc tip master_ip master_svc
  master_svc=""
  master_ip=""
  for svc in "${REDIS_SVCS[@]}"; do
    svc_running "$svc" || continue
    if [[ "$(redis_role "$svc")" == "master" ]] && compose exec -T "$svc" redis-cli SET "e2e:ensure:$$" 1 EX 5 >/dev/null 2>&1; then
      if [[ -z "$master_svc" ]]; then
        master_svc="$svc"
        master_ip=$(svc_ip "$svc")
      else
        compose exec -T "$svc" redis-cli REPLICAOF "$master_ip" 6379 >/dev/null || true
      fi
    fi
  done
  if [[ -z "$master_ip" ]]; then
    for svc in "${REDIS_SVCS[@]}"; do
      svc_running "$svc" || continue
      compose exec -T "$svc" redis-cli REPLICAOF NO ONE >/dev/null || true
      if compose exec -T "$svc" redis-cli SET "e2e:ensure:$$" 1 EX 5 >/dev/null 2>&1; then
        master_svc="$svc"
        master_ip=$(svc_ip "$svc")
        break
      fi
    done
  fi
  [[ -n "$master_ip" ]] || return 1
  for svc in "${REDIS_SVCS[@]}"; do
    [[ "$svc" == "$master_svc" ]] && continue
    svc_running "$svc" || continue
    compose exec -T "$svc" redis-cli REPLICAOF "$master_ip" 6379 >/dev/null || true
  done
  single_writable
}

# Kill ephemeral `compose run` reconciler containers (H5 background loop).
kill_ephemeral_reconcilers() {
  local ids
  ids=$(docker ps -q --filter "name=lab-reconciler" 2>/dev/null || true)
  if [[ -n "$ids" ]]; then
    # shellcheck disable=SC2086
    docker kill $ids >/dev/null 2>&1 || true
  fi
}


reconciler_logs_since() {
  # Prefer reconciler-1 (local to sentinel-1); fall back to legacy service name.
  compose logs reconciler-1 --tail="${1:-80}" 2>/dev/null \
    || compose logs reconciler --tail="${1:-80}" 2>/dev/null \
    || true
}

# Collect reachable Redis seed IPs (comma-separated).
redis_seed_addrs() {
  local addrs=() svc tip
  for svc in "${REDIS_SVCS[@]}"; do
    svc_running "$svc" || continue
    tip=$(svc_ip "$svc" 2>/dev/null || true)
    [[ -n "$tip" ]] && addrs+=("${tip}:6379")
  done
  if ((${#addrs[@]} == 0)); then
    echo "redis-1:6379,redis-2:6379,redis-3:6379,redis-4:6379,redis-5:6379"
  else
    (IFS=,; echo "${addrs[*]}")
  fi
}

# Run reconciler once inside lab network (prefer Redis IPs - DNS flakes under chaos).
# Extra CLI flags after the two positional args: reconciler_once true sentinel-1 -- --heal-cooldown=1m
reconciler_once() {
  local apply="${1:-false}"
  local local_s="${2:-sentinel-1}"
  shift 2 || true
  local extra=()
  [[ "$apply" == "true" || "$apply" == "1" ]] && extra+=(--apply)
  # Optional "--" then passthrough flags (hazard suite).
  if [[ "${1:-}" == "--" ]]; then
    shift
    extra+=("$@")
  fi
  local joined sentinel_addr tip
  joined=$(redis_seed_addrs)
  # Dial Sentinel by container IP. Docker embedded DNS (127.0.0.11) flakes
  # with "server misbehaving" under compose run / chaos (SPEC-SIDECAR, T07).
  if [[ "$local_s" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    sentinel_addr="${local_s}:26379"
  else
    tip=$(svc_ip "$local_s" 2>/dev/null || true)
    if [[ -n "$tip" ]]; then
      sentinel_addr="${tip}:26379"
    else
      sentinel_addr="${local_s}:26379"
    fi
  fi
  compose run --rm --no-deps --entrypoint reconciler reconciler-1 \
    --sentinel-addr="$sentinel_addr" \
    --master-name="$MASTER_NAME" \
    --local-sentinel \
    --quorum="$QUORUM" \
    --heal-cooldown=0 \
    --heal-lease=false \
    --redis-addrs="$joined" \
    --once "${extra[@]}" 2>&1
}

# Low-level reconciler invoke (full control of flags; for hazard / H10).
# Usage: reconciler_raw --sentinel-addr=... --once ...
reconciler_raw() {
  compose run --rm --no-deps --entrypoint reconciler reconciler-1 "$@" 2>&1
}

# HTTP GET inside lab network (metrics scrape; reconciler image has no wget/curl).
lab_http_get() {
  local url="$1"
  docker run --rm --network "$LAB_NET" curlimages/curl:8.7.1 \
    -fsS --max-time 5 "$url" 2>/dev/null \
    || docker run --rm --network "$LAB_NET" alpine/curl \
      -fsS --max-time 5 "$url" 2>/dev/null \
    || return 1
}

# Container IPv4 on lab network.
container_lab_ip() {
  local cid="$1"
  docker inspect -f "{{(index .NetworkSettings.Networks \"$LAB_NET\").IPAddress}}" "$cid" 2>/dev/null \
    || docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$cid"
}

sentinel_master_flags() {
  local s="${1:-sentinel-1}"
  compose exec -T "$s" redis-cli -p 26379 SENTINEL master "$MASTER_NAME" 2>/dev/null \
    | tr -d '\r' | awk '$0=="flags"{getline; print; exit}'
}

# Redis ROLE=master that accepts SET (not Sentinel ad).
writable_master_svc() {
  local s
  for s in "${REDIS_SVCS[@]}"; do
    svc_running "$s" || continue
    if [[ "$(redis_role "$s")" == "master" ]] \
      && compose exec -T "$s" redis-cli SET "e2e:wm:$$" 1 EX 5 >/dev/null 2>&1; then
      echo "$s"
      return 0
    fi
  done
  return 1
}

# Point every running Sentinel at ip; retry until s1 get-master matches (or give up).
force_all_ads() {
  local ip="$1" s i ad
  for i in $(seq 1 8); do
    for s in "${SENTINEL_SVCS[@]}"; do
      svc_running "$s" || continue
      api_point_sentinel "$s" "$ip" || true
    done
    sleep 0.4
    ad=$(sentinel_master_host sentinel-1 2>/dev/null || true)
    [[ "$ad" == "$ip" ]] && return 0
  done
  return 1
}

# Naive operator mistake: MONITOR without consulting oracle (hazard PHASE A).
naive_monitor() {
  local s="$1" ip="$2"
  compose exec -T "$s" redis-cli -p 26379 SENTINEL REMOVE "$MASTER_NAME" >/dev/null 2>&1 || true
  compose exec -T "$s" redis-cli -p 26379 SENTINEL MONITOR "$MASTER_NAME" "$ip" 6379 "$QUORUM" >/dev/null
}

log_has() {
  local haystack="$1" needle="$2"
  echo "$haystack" | grep -q "$needle"
}

# Inject wrong master via SENTINEL API only (no conf file edit).
# Usage: api_lie_sentinel <sentinel-svc> [fake-ip]
api_lie_sentinel() {
  local s="$1" fake="${2:-$FAKE_MASTER_IP}"
  compose exec -T "$s" redis-cli -p 26379 SENTINEL REMOVE "$MASTER_NAME" >/dev/null 2>&1 || true
  compose exec -T "$s" redis-cli -p 26379 SENTINEL MONITOR "$MASTER_NAME" "$fake" 6379 "$QUORUM" >/dev/null
}

api_point_sentinel() {
  local s="$1" ip="$2"
  compose exec -T "$s" redis-cli -p 26379 SENTINEL REMOVE "$MASTER_NAME" >/dev/null 2>&1 || true
  compose exec -T "$s" redis-cli -p 26379 SENTINEL MONITOR "$MASTER_NAME" "$ip" 6379 "$QUORUM" >/dev/null
}

pause_sentinels() {
  local s
  for s in "$@"; do
    compose stop "$s" >/dev/null 2>&1 || true
  done
}

start_sentinels() {
  local s
  for s in "$@"; do
    docker start "$(svc_cid "$s")" >/dev/null 2>&1 || true
  done
}

ensure_lab_up() {
  log "ensuring lab is up (5 Redis + 5 Sentinel, quorum=$QUORUM)..."
  if [[ "${E2E_RESET:-1}" == "1" ]]; then
    log "E2E_RESET=1 - compose down -v for clean topology"
    compose down -v --remove-orphans || true
    # Drop stale named network from older compose projects (label mismatch blocks up).
    docker network rm "$LAB_NET" 2>/dev/null || true
  fi
  compose up -d --build
  MAX_WAIT=180 "$LAB_DIR/scripts/wait-ready.sh" || return 1
  if wait_until "single writable master" 90 single_writable; then
    return 0
  fi
  restore_steady_state
}

# Resolve compose network name for partition tests (stable named net preferred).
lab_net_name() {
  local cid
  cid=$(svc_cid redis-1 2>/dev/null || true)
  [[ -n "$cid" ]] || { echo "$LAB_NET"; return 0; }
  docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{println $k}}{{end}}' "$cid" | head -1
}

current_master_svc() {
  local host svc s
  for s in "${SENTINEL_SVCS[@]}"; do
    svc_running "$s" || continue
    host=$(sentinel_master_host "$s" 2>/dev/null || true)
    [[ -n "$host" && "$host" != "(nil)" ]] || continue
    svc=$(ip_to_redis_svc "$host") && { echo "$svc"; return 0; }
  done
  log "cannot map any sentinel master to redis service"
  return 1
}

oracle_ip() {
  local svc
  svc=$(current_master_svc) || return 1
  svc_ip "$svc"
}

print_summary() {
  local f="$ART_DIR/SUMMARY-$(date -u +%Y%m%dT%H%M%SZ).txt"
  {
    echo "redis-sentinel-reconciler lab e2e (5+5)"
    echo "time_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "pass=$PASS fail=$FAIL skip=$SKIP"
    echo
    echo "## results"
    local r
    for r in "${RESULTS[@]}"; do
      echo "$r"
    done
    echo
    echo "## SPEC §5 coverage"
    echo "A|1 of 5 stale|matrix A"
    echo "B|4 stale / 1 correct; heal toward Redis|matrix B"
    echo "C|all 5 wrong; revive|matrix C"
    echo "D|partition island|matrix D"
    echo "E|dual writable never heal|T05 / matrix E"
    echo "F|no writable|matrix F"
    echo "G|stock failover|T02 / matrix G"
    echo "rejoin|Sentinel REPLICAOF demote|T04"
    echo "API-heal|REMOVE+MONITOR / FAILOVER|T07"
    echo "sidecar|1 reconciler per Sentinel|matrix H"
    echo "hazards|H1-H10 apply-worsens + guards|hazards/"
    echo "stress|short L1 flap/storm|stress/"
  } | tee "$f"
  log "summary -> $f"
  (( FAIL == 0 ))
}

restore_steady_state() {
  log "restore_steady_state..."
  local svc tip master_ip master_svc s
  # Unpause anything left from mid-heal probes (R21).
  for svc in "${REDIS_SVCS[@]}" "${SENTINEL_SVCS[@]}"; do
    docker unpause "$(svc_cid "$svc")" 2>/dev/null || true
  done
  # Reconnect any partitioned containers.
  local net
  net=$(lab_net_name)
  for svc in "${REDIS_SVCS[@]}" "${SENTINEL_SVCS[@]}"; do
    docker network connect "$net" "$(svc_cid "$svc")" 2>/dev/null || true
    docker start "$(svc_cid "$svc")" >/dev/null 2>&1 || true
  done
  sleep 2

  master_svc=""
  master_ip=""
  for svc in "${REDIS_SVCS[@]}"; do
    svc_running "$svc" || continue
    if [[ "$(redis_role "$svc")" == "master" ]] && compose exec -T "$svc" redis-cli SET "e2e:restore:$$" 1 EX 5 >/dev/null 2>&1; then
      if [[ -z "$master_svc" ]]; then
        master_svc="$svc"
        master_ip=$(svc_ip "$svc")
      else
        log "demote extra master $svc -> $master_ip"
        compose exec -T "$svc" redis-cli REPLICAOF "$master_ip" 6379 >/dev/null || true
      fi
    fi
  done
  # After stock election storms all nodes can be role=slave; force one writable.
  if [[ -z "$master_ip" ]]; then
    log "no role=master - promoting first reachable Redis"
    for svc in "${REDIS_SVCS[@]}"; do
      svc_running "$svc" || continue
      compose exec -T "$svc" redis-cli REPLICAOF NO ONE >/dev/null || true
      if compose exec -T "$svc" redis-cli SET "e2e:restore:$$" 1 EX 5 >/dev/null 2>&1; then
        master_svc="$svc"
        master_ip=$(svc_ip "$svc")
        break
      fi
    done
  fi
  [[ -n "$master_ip" ]] || return 1

  for svc in "${REDIS_SVCS[@]}"; do
    [[ "$svc" == "$master_svc" ]] && continue
    svc_running "$svc" || continue
    compose exec -T "$svc" redis-cli REPLICAOF "$master_ip" 6379 >/dev/null || true
  done

  for s in "${SENTINEL_SVCS[@]}"; do
    svc_running "$s" || continue
    api_point_sentinel "$s" "$master_ip" || true
  done
  sleep 2
  single_writable
}

# Comma-separated Sentinel API endpoints by container IP (avoids compose-run DNS flakes).
sentinel_seed_addrs() {
  local addrs=() svc tip
  for svc in "$@"; do
    svc_running "$svc" || continue
    tip=$(svc_ip "$svc" 2>/dev/null || true)
    [[ -n "$tip" ]] && addrs+=("${tip}:26379")
  done
  if ((${#addrs[@]} == 0)); then
  for svc in "${SENTINEL_SVCS[@]}"; do
    svc_running "$svc" || continue
    tip=$(svc_ip "$svc" 2>/dev/null || true)
    [[ -n "$tip" ]] && addrs+=("${tip}:26379")
  done
  fi
  (IFS=,; echo "${addrs[*]}")
}
