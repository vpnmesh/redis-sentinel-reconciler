# RESULT - PRODUCT-READINESS live verify

| Field | Value |
|-------|-------|
| **Verdict** | **CONDITIONAL PASS** (live matrix: fail=0; skip=2) |
| **Run** | `DOCKER_BUILDKIT=0 COMPOSE_DOCKER_CLI_BUILD=0 make e2e-readiness` |
| **Wall** | ~8 min (09:32:05-09:40:04 UTC) |
| **MATRIX** | `lab/e2e/artifacts/readiness/MATRIX-20260809T094004Z.txt` |
| **Counts** | pass=22 fail=0 skip=2 |

## Notes

- First attempt (default BuildKit) failed: `compose up --build` could not resolve `docker.io/docker/dockerfile:1` (IPv6 unreachable); lab never became ready.
- Rerun with classic builder (`DOCKER_BUILDKIT=0`) completed; all live checks recorded under `lab/e2e/artifacts/readiness/`.

## R1-R22 matrix one-liners

- PASS|R1 dry-run would_heal; sentinel ad still fake; no heal
- PASS|R2 CLI refuses --apply without --local-sentinel
- PASS|R3 dual+zero refuse; redis dual=2; no heal
- PASS|R4 partition refuse; no heal
- PASS|R5 oracle stayed master; sentinel ad->oracle
- PASS|R6 heal_cooldown/apply_refused in loop log
- SKIP|R7|lab election window missed; unit TestPreflightFailoverInProgress_H6 binds
- PASS|R8 auth-pass rebind logged after MONITOR
- SKIP|R9|sentinel disagree+equal epoch observed but trap log missing (detector peer sample)
- PASS|R10 Redis lease key=readiness-r10 ttl=119 + reconciler log
- PASS|R11 heal/oracle toward seed 172.26.0.2 not fake ad
- PASS|R12 metrics listening/scrape + alert/grafana files
- PASS|R13 TLS-ACL recipe content
- PASS|R14 systemd unit
- PASS|R14 Helm chart
- PASS|R15 runbook diverge
- PASS|R15 runbook equal-epoch
- PASS|R16 rollout checklist
- PASS|R17 client contract
- PASS|R18 SLO defaults
- PASS|R19 multi-tenant backlog documented
- PASS|R20 release/SBOM sketch
- PASS|R21 conf-escape Owner-GO design
- PASS|R22 stress S3 dualx5 ticks -> refuse only (healed=0 refused=4)

## Key live evidence paths

| Req | Evidence file |
|-----|----------------|
| R1 | `/home/efremov/myprojects/vpnmesh/redis-sentinel-reconciler/lab/e2e/artifacts/readiness/R01_dry_run.txt` |
| R3 | `/home/efremov/myprojects/vpnmesh/redis-sentinel-reconciler/lab/e2e/artifacts/readiness/R03_dual.txt`, `/home/efremov/myprojects/vpnmesh/redis-sentinel-reconciler/lab/e2e/artifacts/readiness/R03_zero.txt` |
| R5 | `/home/efremov/myprojects/vpnmesh/redis-sentinel-reconciler/lab/e2e/artifacts/readiness/R05_promote.txt` |
| R10 | `/home/efremov/myprojects/vpnmesh/redis-sentinel-reconciler/lab/e2e/artifacts/readiness/R10_lease.txt` |
| R11 | `/home/efremov/myprojects/vpnmesh/redis-sentinel-reconciler/lab/e2e/artifacts/readiness/R11_seed.txt` |

### Evidence tails (key checks)

**R1** - dry-run `would_heal`, fake ad sticky:
```
  ## sentinel get-master-addr + config-epoch + flags
  sentinel-1 ad=10.255.255.254:6379 flags=master epoch=0 
  sentinel-2 ad=172.26.0.2:6379 flags=master epoch=0 
  sentinel-3 ad=172.26.0.2:6379 flags=master epoch=0 
  sentinel-4 ad=172.26.0.2:6379 flags=master epoch=0 
  sentinel-5 ad=172.26.0.2:6379 flags=master epoch=0 
```

**R3 dual** - `ALERT dual_master`, writable=2:
```
  writable=2
  {"time":"2026-08-09T09:33:36.385481478Z","level":"ERROR","msg":"ALERT","reason":"dual_master","writable_count":2}
  {"time":"2026-08-09T09:33:36.385588538Z","level":"INFO","msg":"reconciler once complete"}
```

**R5** - heal toward oracle seed, sentinel ad corrected:
```
  redis-4 role=slave SET=ok
  redis-5 role=slave SET=ok
  ## sentinel get-master-addr + config-epoch + flags
  sentinel-1 ad=172.26.0.2:6379 flags=master epoch=0 
```

**R10** - lease + heal log:
```
  lease_val=readiness-r10 ttl=119 ad=172.26.0.2 oracle=172.26.0.2
  {"time":"2026-08-09T09:37:44.677450227Z","level":"INFO","msg":"heal lease acquired","oracle":"172.26.0.2:6379","ttl":"2m0s"}
  {"time":"2026-08-09T09:37:45.694695117Z","level":"INFO","msg":"heal succeeded","action":"SENTINEL REMOVE+MONITOR","sentinel":"sentinel-1:26379","master":"172.26.0.2:6379"}
```

**R11** - REMOVE+MONITOR to `172.26.0.2`, not fake ad:
```
  {"time":"2026-08-09T09:38:20.879632653Z","level":"INFO","msg":"apply heal plan","sentinel":"sentinel-1:26379","failover_safe":true,"reason":"advertised_down_or_unreachable_failover_ok","advertised":"10.255.255.254:6379","oracle":"172.26.0.2:6379","flags":"","equal_epoch_trap":false}
  {"time":"2026-08-09T09:38:21.887257768Z","level":"INFO","msg":"heal succeeded","action":"SENTINEL REMOVE+MONITOR","sentinel":"sentinel-1:26379","master":"172.26.0.2:6379"}
  sentinel-1 ad=172.26.0.2:6379 flags=master epoch=0 
```

## FAIL items

None (fail=0).

## SKIP items (evidence)

| ID | Reason | Evidence |
|----|--------|----------|
| R7 | lab election window missed; unit TestPreflightFailoverInProgress_H6 binds | `/home/efremov/myprojects/vpnmesh/redis-sentinel-reconciler/lab/e2e/artifacts/readiness/R07_failover.txt` |
| R9 | sentinel disagree+equal epoch observed but trap log missing | `/home/efremov/myprojects/vpnmesh/redis-sentinel-reconciler/lab/e2e/artifacts/readiness/R09_epoch.txt` |

**R7 tail:**
```
  {"time":"2026-08-09T09:36:14.216964052Z","level":"WARN","msg":"oracle candidate","addr":"172.26.0.4:6379","role":"slave","writable":false,"err":"<nil>"}
  {"time":"2026-08-09T09:36:14.216971727Z","level":"WARN","msg":"oracle candidate","addr":"172.26.0.5:6379","role":"slave","writable":false,"err":"<nil>"}
  {"time":"2026-08-09T09:36:14.216977508Z","level":"WARN","msg":"oracle candidate","addr":"172.26.0.6:6379","role":"slave","writable":false,"err":"<nil>"}
  {"time":"2026-08-09T09:36:14.216983008Z","level":"WARN","msg":"oracle candidate","addr":"172.26.0.7:6379","role":"slave","writable":false,"err":"<nil>"}
  {"time":"2026-08-09T09:36:14.216990201Z","level":"ERROR","msg":"ALERT","reason":"no_writable_master","probed":4,"discovered":5}
  {"time":"2026-08-09T09:36:14.217050765Z","level":"INFO","msg":"reconciler once complete"}
```

**R9 tail:**
```
  ## sentinel get-master-addr + config-epoch + flags
  sentinel-1 ad=172.26.0.2:6379 flags=master epoch=0 
  sentinel-2 ad=172.26.0.4:6379 flags=master epoch=0 
  sentinel-3 ad=172.26.0.2:6379 flags=master epoch=0 
  sentinel-4 ad=172.26.0.2:6379 flags=master epoch=0 
  sentinel-5 ad=172.26.0.2:6379 flags=master epoch=0 
```

## Suite summary artifact

- `lab/e2e/artifacts/SUMMARY-20260809T094004Z.txt`
- Full log: `/tmp/e2e-readiness-run2.log`
