# RESULT — READINESS LIVE EVIDENCE

| Field | Value |
|-------|-------|
| **Command** | `E2E_RESET=0 make e2e-readiness` |
| **CWD** | `redis-sentinel-reconciler` |
| **Wall** | ~13m (795s) |
| **Make exit** | **1** (FAIL) |
| **Oracle** | pass=17 fail=4 skip=1 |

## FAIL lines

```
FAIL|R12|metrics scrape missing diverge/would_heal or alert/grafana mismatch
FAIL|R17|writer contract evidence incomplete
FAIL|R18|missing dual_master and/or diverge counters
FAIL|R21|expected heal failed + conf_fallback_needed
```

## SKIP

```
SKIP|R19|multi-tenant backlog (not implemented); single master-name live tick only
```

## SUMMARY path

`/home/efremov/myprojects/vpnmesh/redis-sentinel-reconciler/lab/e2e/artifacts/SUMMARY-20260809T120315Z.txt`

## Newest MATRIX-*.txt under `lab/e2e/artifacts/readiness/`

```
-rw-rw-r-- 1 efremov efremov 1171 Aug  9 13:21 /home/efremov/myprojects/vpnmesh/redis-sentinel-reconciler/lab/e2e/artifacts/readiness/MATRIX-20260809T102156Z.txt
-rw-rw-r-- 1 efremov efremov 1232 Aug  9 13:12 /home/efremov/myprojects/vpnmesh/redis-sentinel-reconciler/lab/e2e/artifacts/readiness/MATRIX-20260809T094004Z.txt
```
