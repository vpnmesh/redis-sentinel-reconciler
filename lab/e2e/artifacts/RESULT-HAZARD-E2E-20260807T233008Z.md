# RESULT - Hazard E2E (H1-H10)

| Field | Value |
|-------|-------|
| **Verdict** | **FAIL** |
| **Runner** | Lab Runner (hazard suite) |
| **WORKDIR** | `redis-sentinel-reconciler` |
| **E2E_RESET** | 1 |
| **Wall clock** | ~13 min (769 s incl. compose rebuild; suite 23:17:00-23:29:44 UTC local log) |
| **Exit** | `make e2e-hazards` -> 1 |

## Counts (from SUMMARY)

| pass | fail | skip |
|------|------|------|
| 15 | 1 | 4 |

**SUMMARY:** `/home/efremov/myprojects/vpnmesh/redis-sentinel-reconciler/lab/e2e/artifacts/SUMMARY-20260807T232944Z.txt`

```
pass=15 fail=1 skip=4
time_utc=2026-08-07T23:29:44Z
```

## Per hazard (A/B one-liner)

| Case | Result | Note |
|------|--------|------|
| H1-A | PASS | Naive MONITOR while dual -> cemented split-brain (writable=2) |
| H1-B | PASS | Guarded dual_master refuse, no heal |
| H2-A | PASS | Naive invent MONITOR -> blackhole, writer FAIL |
| H2-B | PASS | Guarded no_writable refuse |
| H3-A | PASS | Island false MONITOR -> writer FAIL |
| H3-B | PASS | Guarded refuse under sparse reachability |
| H4-A | PASS | Naive FAILOVER disturbed topology |
| H4-B | PASS | Guarded M stays writable, ads->oracle |
| H5-A | PASS | Unconstrained MONITOR flap -> blackhole / writer FAIL |
| H5-B | PASS | Guarded heal_cooldown refuse on 2nd storm |
| H6-A | PASS | Naive concurrent FAILOVER storm |
| H6-B | **SKIP** | Election window missed; see `hazard-h6-guard.log` |
| H7-A | PASS | Passwordless lab documents REMOVE+MONITOR class |
| H7-B | **SKIP** | No MONITOR path this tick (noop) |
| H8-A | **FAIL** | Writer OK with unreachable master ad (expected FAIL/blackhole) |
| H8-B | - | Not run (script exits after H8-A fail) |
| H9-A | **SKIP** | Sentinels converged before observe |
| H9-B | **SKIP** | Equal-epoch bump residual / HAZARD still open |
| H10-A | PASS | Parallel MONITOR thundering herd |
| H10-B | PASS | CLI requires `--local-sentinel` |
| H10-B2 | PASS | Local-only heal: s1 OK, s2 stale until sidecar |

## FAIL tail / logs

**H8-A:** No `hazard-h8-guard.log` (H8-B never reached). Failure from suite log:

```
[23:27:51] H8: bad MONITOR IP vs write-probe verify
[23:28:04] FAIL: H8-A - writer OK with unreachable master ad
```

Oracle: after `naive_monitor sentinel-1` with `FAKE_MASTER_IP`, `writer_set_ok` still returned true - apply-worsens blackhole not observed in lab timing/topology.

## Expected / notable skips

- **H6-B**, **H7-B**, **H9-A**, **H9-B** - documented lab flakes or residual hazards; not suite blockers by themselves.

## Parent bind

**FAIL** - do not claim green until H8-A oracle matches hazard spec (writer must fail on unreachable MONITOR ad) or hazard/test adjusted with product owner.
