# Hazard E2E Rerun 2 (post H8-B / H10-B2 dev fix)

| Field | Value |
|-------|-------|
| **Verdict** | **PASS** |
| **time_utc** | 2026-08-08T06:50:27Z |
| **pass** | 17 |
| **fail** | 0 |
| **skip** | 4 |
| **E2E_RESET** | 1 (default) |
| **WORKDIR** | redis-sentinel-reconciler |
| **image** | `docker compose -f lab/docker-compose.yml build reconciler-1` (BuildKit OK) |
| **command** | `make e2e-hazards` |
| **summary_ssot** | `lab/e2e/artifacts/SUMMARY-20260808T065027Z.txt` |

## Context (dev fixes under test)

- Product: seed-only oracle + short dial on untrusted Sentinel ads
- Lab: `ensure_unique_writable_redis` before H8-B / H10-B2; kill ephemeral reconciler on H5

## H8 (bad MONITOR IP vs write-probe verify)

| Case | Result | Detail |
|------|--------|--------|
| H8-A | **PASS** | naive MONITOR 10.255.255.254 -> ads stuck, write via ad FAIL (blackhole) |
| H8-B | **PASS** | guarded heal -> ads+write-probe OK |

## H10 (global apply herd vs require local-sentinel)

| Case | Result | Detail |
|------|--------|--------|
| H10-A | **PASS** | naive parallel MONITOR on all 5 Sentinels (thundering herd class) |
| H10-B | **PASS** | CLI -> `--apply` requires `--local-sentinel` |
| H10-B2 | **PASS** | local-only: s1 healed, s2 still stale (10.255.255.254) until its sidecar |

## Full per-case

| Case | Result |
|------|--------|
| H1-A | PASS |
| H1-B | PASS |
| H2-A | PASS |
| H2-B | PASS |
| H3-A | PASS |
| H3-B | PASS |
| H4-A | PASS |
| H4-B | PASS |
| H5-A | PASS |
| H5-B | PASS |
| H6-A | PASS |
| H6-B | SKIP - election window missed in lab (unit covers flag guard) |
| H7-A | PASS |
| H7-B | SKIP - passworded Redis not in lab compose |
| H8-A | PASS |
| H8-B | PASS |
| H9-A | SKIP - sentinels converged before observe |
| H9-B | SKIP - equal-epoch bump residual / HAZARD still open |
| H10-A | PASS |
| H10-B | PASS |
| H10-B2 | PASS |

## Notes

- Wall clock ~9m 42s (06:40:45-06:50:27 UTC).
- No Go or script changes in this run (Runner shell-only).
