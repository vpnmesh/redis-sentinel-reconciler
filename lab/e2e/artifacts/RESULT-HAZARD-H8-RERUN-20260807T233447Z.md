# H8 hazard re-run (peer-Hello race fix)

**Runner:** Lab Runner (focused H08_bad_monitor_ip.sh)  
**time_utc:** 2026-08-07T23:34:43Z  
**E2E_RESET:** 0 (lab already up)  
**Verdict:** **PASS**

| Case | Result |
|------|--------|
| H8-A | **PASS** - naive MONITOR 10.255.255.254 -> ads stuck, write via ad FAIL (blackhole) |
| H8-B | **PASS** - guarded heal -> ads+write-probe OK |

**Counters:** pass=2 fail=0 skip=0

## Context

Re-verification after dev fixed peer-Hello race in `lab/e2e/hazards/H08_bad_monitor_ip.sh`.

## Log tail (summary)

```
[23:31:04] H8: bad MONITOR IP vs write-probe verify
[23:34:25] PASS: H8-A naive MONITOR 10.255.255.254 -> ads stuck, write via ad FAIL (blackhole)
[23:34:43] PASS: H8-B guarded heal -> ads+write-probe OK
```

Full summary: `lab/e2e/artifacts/SUMMARY-20260807T233443Z.txt`

## Fail log tails

N/A (all PASS)
