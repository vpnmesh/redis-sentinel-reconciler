# Hazard E2E rerun - Lab Runner ART

| Field | Value |
|-------|-------|
| **Verdict** | **FAIL** |
| **pass / fail / skip** | 15 / 2 / 4 |
| **E2E_RESET** | 1 (full `compose down -v`) |
| **Wall clock** | ~11m 24s (06:26:56 -> 06:38:16 UTC, make exit 1) |
| **SUMMARY** | `lab/e2e/artifacts/SUMMARY-20260808T063816Z.txt` |
| **Runner** | `make e2e-hazards` @ `/home/efremov/myprojects/vpnmesh/redis-sentinel-reconciler` |
| **time_utc (SUMMARY)** | 2026-08-08T06:38:16Z |

## H1-H10 (A/B one-liners)

| Case | Result | One-liner |
|------|--------|-----------|
| H1-A | PASS | Naive MONITOR while dual -> cemented split-brain ads (writable=2) |
| H1-B | PASS | Guarded -> dual_master refuse, no heal |
| H2-A | PASS | Naive invent MONITOR -> blackhole ads, writer FAIL |
| H2-B | PASS | Guarded -> no_writable refuse, no invent |
| H3-A | PASS | Island false MONITOR -> writer FAIL (false-oracle cement risk) |
| H3-B | PASS | Guarded -> refuse under sparse reachability |
| H4-A | PASS | Naive FAILOVER disturbed topology - apply can worsen |
| H4-B | PASS | Guarded -> M stays writable, ads->oracle (promote-safe) |
| H5-A | PASS | Unconstrained MONITOR flap -> blackhole ads / writer FAIL |
| H5-B | PASS | Guarded -> heal_cooldown refuse on 2nd storm |
| H6-A | PASS | Naive concurrent FAILOVER during master-down election |
| H6-B | SKIP | Election window missed in lab (unit covers flag guard) |
| H7-A | PASS | Lab passwordless: REMOVE+MONITOR class documented |
| H7-B | SKIP | Passworded Redis not in lab compose; healAPI unit coverage |
| H8-A | PASS | Naive MONITOR 10.255.255.254 -> blackhole, write FAIL |
| H8-B | **FAIL** | Expected heal to oracle; reconciler reported `no_writable_master` |
| H9-A | SKIP | Sentinels converged before observe; equal-epoch residual |
| H9-B | SKIP | Strong equal-epoch bump without demote M still open |
| H10-A | PASS | Naive parallel MONITOR on all 5 Sentinels (herd class) |
| H10-B | PASS | CLI `--apply` requires `--local-sentinel` |
| H10-B2 | **FAIL** | Local s1 not healed to 172.26.0.6 (got 10.255.255.254) |

## FAIL tails

### H8-B

```
{"time":"2026-08-08T06:37:18.321524088Z","level":"INFO","msg":"reconciler started","master_name":"mymaster","interval":5000000000,"apply":true,"once":true,"local_sentinel":true,"heal_cooldown":0,"sentinels":["sentinel-1:26379"]}
{"time":"2026-08-08T06:37:21.721253338Z","level":"WARN","msg":"redis probe failed","addr":"10.255.255.254:6379","err":"dial tcp 10.255.255.254:6379: i/o timeout"}
{"time":"2026-08-08T06:37:21.721298172Z","level":"ERROR","msg":"ALERT","reason":"no_writable_master","probed":6}
{"time":"2026-08-08T06:37:21.721388994Z","level":"INFO","msg":"reconciler once complete"}
```

### H10-B2

```
local s1 not healed to 172.26.0.6 (got 10.255.255.254)
```

## Notable skips

- **H6-B** - timing/election window; see `hazard-h6-guard.log`
- **H7-B** - no passworded Redis in compose
- **H9-A / H9-B** - equal-epoch hazard residual / stock Hello convergence

## SUMMARY pass/fail lines (canon)

From SUMMARY: `pass=15 fail=2 skip=4`; suite exit **FAIL** (make error 1).
