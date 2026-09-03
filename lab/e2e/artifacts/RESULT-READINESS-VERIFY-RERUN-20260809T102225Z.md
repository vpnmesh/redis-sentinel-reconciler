# PRODUCT-READINESS verify rerun (R7 unit bind + R9 equal-epoch detector)

**Verdict:** PASS  
**time_utc:** 2026-08-09T10:21:56Z  
**counts:** pass=24 fail=0 skip=0  
**summary:** `lab/e2e/artifacts/SUMMARY-20260809T102156Z.txt`  
**matrix:** `lab/e2e/artifacts/readiness/MATRIX-20260809T102156Z.txt`

## Runner notes

- Rebuilt `reconciler-1` with `DOCKER_BUILDKIT=0 COMPOSE_DOCKER_CLI_BUILD=0`.
- First full run: segfault after R8 (docker/make); partial rerun (E2E_RESET=0) showed **R9 FAIL** — reconciler could not dial `sentinel-2` by hostname (`lookup sentinel-2 … server misbehaving`), `sample_size=1`, `trap=false`.
- **Shell fix (lab only):** added `sentinel_seed_addrs()` in `lab/e2e/lib.sh`; R9 uses `--sentinel-addr="$(sentinel_seed_addrs sentinel-1 sentinel-2)"` (IPs) in `lab/e2e/readiness/run.sh`.
- Final **E2E_RESET=1** run: **pass=24 fail=0**.

## R7 (skip-on-failover-in-progress)

- **PASS** — `unit TestPreflightFailoverInProgress_H6 PASS` (`readiness/R07_failover.txt` @ 2026-08-09T10:18:23Z).

## R9 (equal-epoch trap)

- **PASS** — `equal_epoch_trap in reconciler log (ads/epochs evidence)`.
- Trap line (cite):

```json
{"time":"2026-08-09T10:19:11.376980822Z","level":"ERROR","msg":"ALERT","reason":"equal_epoch_trap","sample_size":2,"ads":["172.26.0.2:6379","172.26.0.3:6379"],"epochs":null}
```

- Preceding sample: `equal_epoch_sample` with `"trap":true,"sample_size":2`.
- Topology: `ad1=172.26.0.2 ad2=172.26.0.3 ep1=0 ep2=0` (disagreeing ads, equal epoch 0).

## MATRIX counts (copied)

PRODUCT-READINESS live verify
time_utc=2026-08-09T10:21:56Z
pass=24 fail=0 skip=0
evidence=/home/efremov/myprojects/vpnmesh/redis-sentinel-reconciler/lab/e2e/artifacts/readiness
PASS|R1 dry-run would_heal; sentinel ad still fake; no heal
PASS|R2 CLI refuses --apply without --local-sentinel
PASS|R3 dual+zero refuse; redis dual=2; no heal
PASS|R4 partition refuse; no heal
PASS|R5 oracle stayed master; sentinel ad->oracle
PASS|R6 heal_cooldown/apply_refused in loop log
PASS|R7 skip-on-failover-in-progress unit PASS
PASS|R8 auth-pass rebind logged after MONITOR
PASS|R9 equal_epoch_trap in reconciler log (ads/epochs evidence)
PASS|R10 Redis lease key=readiness-r10 ttl=119 + reconciler log
PASS|R11 heal/oracle toward seed 172.26.0.2 not fake ad
PASS|R12 metrics listening/scrape + alert/grafana files
PASS|R13 TLS-ACL recipe content
PASS|R14 systemd unit
PASS|R14 Helm chart
PASS|R15 runbook diverge
PASS|R15 runbook equal-epoch
PASS|R16 rollout checklist
PASS|R17 client contract
PASS|R18 SLO defaults
PASS|R19 multi-tenant backlog documented
PASS|R20 release/SBOM sketch
PASS|R21 conf-escape Owner-GO design
PASS|S3 dualx5 ticks -> refuse only (healed=0 refused=5)
