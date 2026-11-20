# Short stress

Not a soak. About 3–8 minutes on a warm lab, 10–15 with `E2E_RESET=1`.

```bash
make e2e-stress
STRESS_ROUNDS=12 make e2e-stress
```

| Case | Checks |
|------|--------|
| S1 | MONITOR flap xN: guarded heal, one writable, writer still works |
| S2 | Five parallel apply attempts: no dual writable |
| S3 | Dual master x5 ticks: refuse only |
| S4 | Parallel apply with `--heal-lease`: one holder |
| S5 | Throwaway Sentinel: `MONITOR` stores the `--redis-addrs` hostname when that node's IP is listed first |

S1–S4 pass container IPs from `redis_seed_addrs()` and expect `get-master-addr-by-name` to be that IP. The lab entrypoint rewrites the template hostname to an IPv4, and `lab/config/sentinel-*.conf` does not set `resolve-hostnames` or `announce-hostnames`, so those Sentinels reject a hostname `MONITOR`. S5 does not change sentinel-1..5. It starts a Sentinel with both flags and its own master name, then checks the command argument, `sentinel.conf`, and `get-master-addr-by-name`.
