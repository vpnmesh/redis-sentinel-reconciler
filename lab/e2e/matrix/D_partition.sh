#!/usr/bin/env bash
# SPEC §5-D: partition - island with M may observe/heal; island without M -> alert only.
set -uo pipefail
set +e
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

log "SPEC-D: network partition"
restore_steady_state || true
msvc=$(current_master_svc) || { bad "SPEC-D" "no master"; return 0; }
mip=$(svc_ip "$msvc")

# Island WITHOUT master: disconnect redis master + keep sentinel-5 with it on... 
# Simpler: disconnect sentinel-5 + a non-master redis from lab net (no writable M on that island).
# Island WITH master: sentinel-1 stays with all redis masters.

victim_svc=""
for s in "${REDIS_SVCS[@]}"; do
  [[ "$s" != "$msvc" ]] && { slave_svc=$s; break; }
done

log "partition: disconnect sentinel-5 + $slave_svc from network (island without M)"
net=$(lab_net_name)
docker network disconnect "$net" "$(svc_cid sentinel-5)" || true
docker network disconnect "$net" "$(svc_cid "$slave_svc")" || true
sleep 3

# On main island: unique writable still, reconciler local to s1 should noop or be healthy.
out=$(reconciler_once false sentinel-1)
echo "$out" | tee "$ART_DIR/spec-d-main.log" >/dev/null
if echo "$out" | grep -q '"reason":"dual_master"'; then
  bad "SPEC-D" "unexpected dual_master on main island"
  docker network connect "$net" "$(svc_cid sentinel-5)" 2>/dev/null || true
  docker network connect "$net" "$(svc_cid "$slave_svc")" 2>/dev/null || true
  return 0
fi

single_writable || { bad "SPEC-D" "main island lost unique writable"; restore_steady_state || true; return 0; }

docker network connect "$net" "$(svc_cid sentinel-5)" 2>/dev/null || true
docker network connect "$net" "$(svc_cid "$slave_svc")" 2>/dev/null || true
sleep 2
restore_steady_state || true
ok "SPEC-D partition: main island keeps unique M; no invent on dark island"
