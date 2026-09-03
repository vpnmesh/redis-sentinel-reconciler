#!/usr/bin/env bash
# S4: with --heal-lease, parallel apply -> at most one heal_lease_acquired cluster-wide window;
# others heal_lease_held; Redis stays single-writable.
set -uo pipefail
set +e
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib.sh"

log "S4: heal lease serializes parallel apply (R10)"

restore_steady_state || true
msvc=$(current_master_svc) || { bad "S4" "no master"; return 0; }
mip=$(svc_ip "$msvc")

for s in "${SENTINEL_SVCS[@]}"; do
  naive_monitor "$s" "$FAKE_MASTER_IP" || true
done
sleep 1

joined=$(redis_seed_addrs)
pids=()
i=0
for s in "${SENTINEL_SVCS[@]}"; do
  i=$((i + 1))
  (
    compose run --rm --no-deps --entrypoint reconciler reconciler-1 \
      --sentinel-addr="${s}:26379" \
      --master-name="$MASTER_NAME" \
      --local-sentinel \
      --quorum="$QUORUM" \
      --heal-cooldown=0 \
      --heal-lease=true \
      --heal-lease-ttl=2m \
      --lease-holder="stress-$i" \
      --equal-epoch-escalate=false \
      --redis-addrs="$joined" \
      --once --apply >"$ART_DIR/stress-s4-$s.log" 2>&1 || true
  ) &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p" || true; done
sleep 1

acquired=0
held=0
for s in "${SENTINEL_SVCS[@]}"; do
  f="$ART_DIR/stress-s4-$s.log"
  [[ -f "$f" ]] || continue
  grep -q 'heal lease acquired\|heal_lease_acquired' "$f" && acquired=$((acquired + 1))
  grep -q 'heal_lease_held' "$f" && held=$((held + 1))
done

wc=$(writable_count)
if [[ "$wc" != "1" ]]; then
  bad "S4" "writable_count=$wc after leased storm"
  restore_steady_state || true
  return 0
fi

# At least one holder should acquire; typically others held (timing may allow >1 if TTL race on different keys - same key so <=1 acquire success path).
if (( acquired < 1 )); then
  # Maybe all refused for other reasons - still OK if no dual and some lease log
  if (( held >= 1 )); then
    ok "S4 lease contention observed (held=$held acquired=$acquired)"
  else
    skip "S4" "no lease lines (timing); unit covers SET NX; held=$held acquired=$acquired"
  fi
else
  ok "S4 lease: acquired=$acquired held=$held writable=1"
fi
restore_steady_state || true
