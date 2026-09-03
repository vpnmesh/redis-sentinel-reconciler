# RESULT — readiness live evidence (E2E_RESET=0)

| Field | Value |
|-------|-------|
| **Gate** | `E2E_RESET=0 make e2e-readiness` |
| **CWD** | `/home/efremov/myprojects/vpnmesh/redis-sentinel-reconciler` |
| **Wall** | ~12.4 min (743s) |
| **Exit code** | **1** (`make: *** [Makefile:41: e2e-readiness] Error 1`) |
| **pass / fail / skip** | **17 / 4 / 1** |
| **time_utc (summary)** | 2026-08-09T11:30:23Z |

## Newest artifact paths

| Artifact | Path |
|----------|------|
| SUMMARY | `/home/efremov/myprojects/vpnmesh/redis-sentinel-reconciler/lab/e2e/artifacts/SUMMARY-20260809T113023Z.txt` |
| MATRIX (newest under `lab/e2e/artifacts`) | `/home/efremov/myprojects/vpnmesh/redis-sentinel-reconciler/lab/e2e/artifacts/readiness/MATRIX-20260809T102156Z.txt` |

Note: this readiness run did not emit a new `MATRIX-*.txt`; newest MATRIX predates this run (102156Z).

## FAIL lines

```
FAIL|R15|runbook↔log bind failed ad_ks=172.26.0.5
FAIL|R16|obs=172.26.0.5 can=172.26.0.5 frz=172.26.0.5 mip=172.26.0.5
FAIL|R17|writer contract evidence incomplete
FAIL|R21|expected heal failed + conf_fallback_needed
```

## SKIP

```
SKIP|R19|multi-tenant backlog (not implemented); single master-name live tick only
```

## Verdict

**FAIL** — 4 readiness rows red (R15, R16, R17, R21).
