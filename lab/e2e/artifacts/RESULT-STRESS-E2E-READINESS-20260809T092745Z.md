# RESULT - stress e2e readiness (short L1, S1-S4)

| Field | Value |
|-------|-------|
| **Verdict** | **PASS** |
| **time_utc** | 2026-08-09T09:27:45Z |
| **suite** | stress (short L1, rounds=8) |
| **E2E_RESET** | 1 (compose down -v clean topology) |
| **pass** | 4 |
| **fail** | 0 |
| **skip** | 0 |
| **wall** | ~4m (09:23:47 -> 09:27:45 UTC log) |
| **image** | `lab-reconciler-1` config `090ed4b221b5` |
| **SUMMARY** | `lab/e2e/artifacts/SUMMARY-20260809T092745Z.txt` |
| **pack** | PRODUCT-READINESS R7-R22 (heal-lease, equal-epoch escalate, deploy docs) |

## S1-S4

| ID | Result | Detail |
|----|--------|--------|
| S1 | PASS | flapx8 -> heal keeps single writable + writer OK |
| S2 | PASS | parallel applyx5 -> single writable + writer OK (lease R10 still open) |
| S3 | PASS | dualx5 ticks -> refuse only (healed=0 refused=5) |
| S4 | PASS | heal lease (R10): acquired=1 held=4 writable=1 - parallel apply serialized |

### S4 note

Five parallel apply attempts under flap/steady-state: exactly one reconciler **acquired** the heal lease; four **held** (blocked on lease); topology ended with **writable=1**. Confirms R10 heal-lease gate after readiness pack.

## Command

```bash
export PATH="/usr/bin:/bin:/usr/local/bin:$PATH"
docker compose -f lab/docker-compose.yml build reconciler-1
make e2e-stress
```

## Canon

`docs/PRODUCT-READINESS.md` §4 - `lab/e2e/stress/run.sh`
