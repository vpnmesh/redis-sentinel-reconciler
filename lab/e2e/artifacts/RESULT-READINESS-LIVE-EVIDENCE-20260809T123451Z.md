# RESULT — PRODUCT-READINESS live evidence (R1–R22)

| Field | Value |
|-------|-------|
| **Command** | `E2E_RESET=0 make e2e-readiness` |
| **Exit** | **0** |
| **Score** | **pass=21 fail=0 skip=1** |
| **Duration** | ~15m (wall; 12:19:45–12:34:47 UTC) |
| **SUMMARY** | `lab/e2e/artifacts/SUMMARY-20260809T123447Z.txt` |
| **Evidence dir** | `lab/e2e/artifacts/readiness` |

## FAIL

_(none)_

## SKIP

| ID | Detail |
|----|--------|
| R19 | multi-tenant backlog (not implemented); single master-name live tick only |

## Matrix (pass/fail/skip)

- PASS|R1 dry-run would_heal; sentinel ad still fake; no heal
- PASS|R2 CLI refuses --apply without --local-sentinel
- PASS|R3 dual+zero refuse; redis dual=2; no heal
- PASS|R4 partition refuse; no heal
- PASS|R5 oracle stayed master; sentinel ad->oracle
- PASS|R6 heal_cooldown/apply_refused in loop log
- PASS|R7 election: no heal while master down + unit flag parse PASS
- PASS|R8 auth-pass rebind logged after MONITOR
- PASS|R9 equal_epoch_trap in reconciler log (ads/epochs evidence)
- PASS|R10 Redis lease key=readiness-r10 ttl=119 + reconciler log
- PASS|R11 heal/oracle toward seed 172.26.0.7 not fake ad
- PASS|R12 live /metrics diverge|would_heal + alert/grafana expr bind
- PASS|R13 live requirepass: NOAUTH without pass; heal+SET with --redis-password
- PASS|R14 systemd-equivalent once boot + Helm/DaemonSet render
- PASS|R15 runbooks ↔ live diverge/dual/kill-switch (+ equal-epoch ART)
- PASS|R16 observe→apply canary→kill-switch freeze (ads+logs)
- PASS|R17 writer SET ok → fail on lie → SET ok after heal
- PASS|R18 live metrics: dual_master + diverge/would_heal (SLO counters)
- SKIP|R19|multi-tenant backlog (not implemented); single master-name live tick only
- PASS|R20 live Redis/go version matrix (syft not installed - SBOM CI residual)
- PASS|R21 live heal failed conf_fallback_needed (Owner escape signal)
- PASS|S3 dualx5 ticks -> refuse only (healed=0 refused=5)

## Verdict

**PASS** — live matrix green; R19 skip expected.
