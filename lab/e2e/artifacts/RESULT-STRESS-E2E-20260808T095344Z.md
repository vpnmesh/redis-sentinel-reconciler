# RESULT - stress e2e (short L1)

| Field | Value |
|-------|-------|
| **Verdict** | **PASS** |
| **time_utc** | 2026-08-08T09:53:39Z |
| **suite** | stress (short L1, rounds=8) |
| **E2E_RESET** | 1 (clean topology via ensure_lab_up) |
| **pass** | 3 |
| **fail** | 0 |
| **skip** | 0 |
| **wall** | ~3m 45s (09:49:54 -> 09:53:39 local log) |
| **SUMMARY** | `lab/e2e/artifacts/SUMMARY-20260808T095339Z.txt` |

## S1 / S2 / S3

| ID | Result | Detail |
|----|--------|--------|
| S1 | PASS | flapx8 -> heal keeps single writable + writer OK |
| S2 | PASS | parallel applyx5 -> single writable + writer OK (lease R10 still open) |
| S3 | PASS | dualx5 ticks -> refuse only (healed=0 refused=4) |

## Command

```bash
make e2e-stress
```

## Canon

`docs/PRODUCT-READINESS.md` §4 - `lab/e2e/stress/run.sh`
