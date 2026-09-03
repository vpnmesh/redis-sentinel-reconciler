# RESULT — PRODUCT-READINESS live evidence (R1–R22)

| Field | Value |
|-------|-------|
| **Command** | `E2E_RESET=0 make e2e-readiness` |
| **Exit** | **2** (make failure) |
| **Score** | **pass=19 fail=2 skip=1** |
| **Duration** | ~14m (wall) |
| **SUMMARY** | `lab/e2e/artifacts/SUMMARY-20260809T121853Z.txt` |
| **Evidence dir** | `lab/e2e/artifacts/readiness` |

## FAIL

| ID | Detail |
|----|--------|
| R10 | `lease_val=` `ttl=-2` |
| R13 | `nopass=NOAUTH Authentication required.` `withpass=PONG` `ad=172.26.0.4` `mip=172.26.0.4` `set=READONLY You can't write against a read only replica.` |

## SKIP

| ID | Detail |
|----|--------|
| R19 | multi-tenant backlog (not implemented); single master-name live tick only |

## Verdict

**FAIL** — lease (R10) and auth/read-only replica (R13) red on live lab.
