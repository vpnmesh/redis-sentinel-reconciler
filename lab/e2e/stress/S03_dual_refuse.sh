#!/usr/bin/env bash
# S3: dual-master under flap - reconciler must never heal (refuse), topology not cemented by apply.
set -uo pipefail
set +e
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

log "S3: dual_master stress - refuse apply"

restore_steady_state || true
msvc=$(current_master_svc) || { bad "S3" "no master"; return 0; }
mip=$(svc_ip "$msvc")
slave=""
for s in "${REDIS_SVCS[@]}"; do
  [[ "$s" != "$msvc" && "$(redis_role "$s")" == "slave" ]] && { slave=$s; break; }
done
[[ -n "$slave" ]] || { bad "S3" "no slave"; return 0; }

pause_sentinels "${SENTINEL_SVCS[@]}"
compose exec -T "$slave" redis-cli REPLICAOF NO ONE >/dev/null
dual=0
for _ in $(seq 1 20); do
  [[ "$(writable_count)" -ge 2 ]] && { dual=1; break; }
  sleep 1
done
if [[ "$dual" != "1" ]]; then
  bad "S3" "failed to inject dual"
  start_sentinels "${SENTINEL_SVCS[@]}"
  restore_steady_state || true
  return 0
fi

docker start "$(svc_cid sentinel-1)" >/dev/null
sleep 1

refused=0
healed=0
for i in $(seq 1 5); do
  out=$(reconciler_once true sentinel-1)
  echo "$out" | grep -q '"reason":"dual_master"' && refused=$((refused + 1))
  echo "$out" | grep -q 'heal succeeded' && healed=$((healed + 1))
done

start_sentinels "${SENTINEL_SVCS[@]}"
restore_steady_state || true

if (( healed > 0 )); then
  bad "S3" "heal succeeded under dual ($healed)"
  return 0
fi
if (( refused < 3 )); then
  bad "S3" "expected repeated dual_master refuse (got $refused/5)"
  return 0
fi
ok "S3 dualx5 ticks -> refuse only (healed=0 refused=$refused)"
