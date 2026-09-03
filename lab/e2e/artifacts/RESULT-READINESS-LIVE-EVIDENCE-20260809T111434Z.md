# RESULT: e2e-readiness live evidence

- **UTC:** 2026-08-09T11:14:34Z
- **Command:** `make e2e-readiness` (runs `lab/e2e/readiness/run.sh`, R1–R22 + S3 stress)
- **Exit code:** 1 (make failed due to FAIL rows; harness completed)
- **Counts:** pass=15 fail=5 skip=2

## Artifacts

> This run did not emit a new MATRIX file; latest on disk is from prior run (stale pass=24). **Authoritative for this invocation:** SUMMARY below.

- **MATRIX:** `lab/e2e/artifacts/readiness/MATRIX-20260809T102156Z.txt`
- **SUMMARY:** `lab/e2e/artifacts/SUMMARY-20260809T111429Z.txt`

## FAIL lines

```
FAIL|R9|no equal_epoch evidence ad1=172.26.0.7 ad2=172.26.0.2
FAIL|R10|lease_val= ttl=-2
FAIL|R14|unit/boot/helm evidence incomplete helm_ok=0
FAIL|R17|writer contract evidence incomplete
FAIL|R21|expected heal failed + conf_fallback_needed
```

## Note

R12–R21 in this run are **live** lab checks (containers, metrics, requirepass, canary/kill-switch, SLO counters, conf fallback, etc.), not doc-only matrix rows. R8 and R19 were SKIP (MONITOR path / multi-tenant backlog).

## Lab bring-up

Harness invoked `ensure_lab_up` with E2E_RESET=1 (compose down -v, rebuild, up). Wall clock ~10.6 min for this invocation.

