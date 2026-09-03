# RESULT — readiness live evidence (E2E_RESET=0)

| Field | Value |
|-------|-------|
| **Gate** | `E2E_RESET=0 make e2e-readiness` |
| **CWD** | `/home/efremov/myprojects/vpnmesh/redis-sentinel-reconciler` |
| **Wall** | ~13.3 min (799s) |
| **Exit code** | **2** (`make: *** [Makefile:41: e2e-readiness] Error 1`) |
| **pass / fail / skip** | **19 / 2 / 1** |
| **time_utc (summary)** | 2026-08-09T11:48:28Z |

## Newest artifact paths

| Artifact | Path |
|----------|------|
| SUMMARY | `/home/efremov/myprojects/vpnmesh/redis-sentinel-reconciler/lab/e2e/artifacts/SUMMARY-20260809T114828Z.txt` |
| MATRIX (newest under `readiness/`) | `/home/efremov/myprojects/vpnmesh/redis-sentinel-reconciler/lab/e2e/artifacts/readiness/MATRIX-20260809T102156Z.txt` |

Note: this readiness run did not emit a new `MATRIX-*.txt`; newest MATRIX under `readiness/` predates this run (102156Z).

## FAIL lines

```
FAIL|R16|obs=10.255.255.254 can=172.26.0.2 frz=10.255.255.254 mip=172.26.0.7
FAIL|R17|writer contract evidence incomplete
```

## SKIP

```
SKIP|R19|multi-tenant backlog (not implemented); single master-name live tick only
```

## Verdict

**FAIL** — 2 readiness rows red (R16, R17).
