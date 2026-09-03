# Operations

Alerts scrape `--metrics-addr` (`/metrics`, example `127.0.0.1:9123`).
Scrape ~15s, reconcile interval ~30s. Rule examples:
[`deploy/observability/prometheus-alerts.yaml`](../deploy/observability/prometheus-alerts.yaml).

Counters (`*_total`, registered at 0, HELP/TYPE on the wire) count **ticks**.
`diverge_total` goes up every diverged tick while the split lasts — that is
not “multiplied by scrape”. Use `rate`/`increase`. Last-tick gauges:
`diverged` 0|1, `would_heal` 0|1, `writable_masters`.

Rename from v0.1.0: `diverge` → `diverge_total`, `would_heal` (counter) →
`would_heal_total` (the gauge kept the old name `would_heal`). Same for
`heal_*`, `alert_*`, `apply_refused`, `ticks`, `noop`.

Const labels: `master_name`, `apply`. No advertised-master / epoch / tick id.

## Observe, then maybe apply

Run one sidecar per Sentinel with `APPLY=false` until the logs look
boring: ticks, occasional `would_heal`, no surprise `dual_master`.

Canary apply is one host, `--local-sentinel`, cooldown 15m, lease on.
If that host misbehaves, freeze apply everywhere (kill switch below)
before touching the rest.

Lab green is not a soak. Watch a real cluster first.

## Kill switch

Set `APPLY=false` in `/etc/default/redis-sentinel-reconciler` on every
host (or drop `--apply` from Helm) and restart the unit. You should see
`"apply":false` on the start line and `would_heal` without
`heal succeeded`.

Freeze apply on a `heal_fail` spike, epoch churn, an unexpected demote,
or any dual-writable window you do not understand.

## Diverge

Sentinel ads ≠ writable Redis. Log line `DIVERGE`, counter `diverge_total`,
gauge `diverged=1`.

1. Count writable nodes (`ROLE` + `SET` on the seed list).
2. Two or more writables → dual-master, do **not** `--apply`.
3. `equal_epoch_trap` → equal-epoch section below.
4. Still one writable and ads are wrong: dry-run should log `would_heal`.
   With `--apply` the local sidecar heals toward that oracle, then
   write-probes it.

## Dual master

`alert_dual_master`. The reconciler will not heal. That is the point —
picking a side with `MONITOR` cements a split-brain.

Find who should be master, demote the extra with `REPLICAOF` (Sentinel
usually does this; do it by hand if it is stuck). When you are back to
one writable, leftover stale ads are just diverge.

Do not `--apply` while two nodes still accept writes. Do not restart a
single island “to clear the alert”.

## Equal-epoch trap

Two Sentinels advertise different masters with the same `config-epoch`.
Hello from the peer is ignored, so the lie never heals itself. Logs:
`equal_epoch_trap`.

FAILOVER is still refused when the advertised address is a **live slave**
(even if flags say `s_down,master`) or a live writable that is not the
oracle. FAILOVER unsafe is **not** the same as MONITOR unsafe.

When there is exactly one writable oracle and the local ad is a live
replica (stale `s_down,master`), APPLY with default
`--equal-epoch-escalate=true` does `REMOVE`+`MONITOR` onto that oracle
and re-binds Sentinel→Redis auth. That does not need a new config-epoch.
The other sidecars noop. Operators should not turn escalate off for this.

Escalate + refuse MONITOR still applies when FAILOVER was skipped for
any other reason (extra live writable, unknown promote risk). Dual
writable never FAILOVER and never MONITOR.

Keep client write-probes up until ads agree.

## API heal failed (`conf_fallback_needed`)

The process does not rewrite `sentinel.conf` and does not restart
Sentinel. If FAILOVER / MONITOR / RESET all fail, it logs
`conf_fallback_needed` and leaves the rest to you:

1. Backup `sentinel.conf`.
2. `sentinel monitor <name> <oracle-ip> <port> <quorum>`.
3. Set `config-epoch` / `current-epoch` to `max(observed)+1`.
4. Restore `auth-user` and `auth-pass` if you use ACL or a password.
5. Restart Sentinel, then check ads and a write.

Automating that is a later, explicit flag. It is not on by default.

## Why `--apply` sometimes refuses

These are the cases where healing would make an outage worse. The
process already refuses; do not override them.

| | Situation | If we healed anyway |
|---|-----------|---------------------|
| H1 | Dual writable Redis | Cement split-brain |
| H2 | Zero writable | Invent a blackhole master |
| H3 | Partition island (too few seeds reachable) | Two client “truths” |
| H4 | `FAILOVER` would promote someone other than the oracle | Demote the real master |
| H5 | Heal storm | Flapping epochs |
| H6 | Stock failover already in progress | Fight the election |
| H7 | MONITOR without re-binding auth-user/auth-pass | Sentinel cannot talk to Redis |
| H8 | MONITOR a fake / unreachable IP | Client blackhole |
| H9 | Equal epoch, FAILOVER skip is not a live-replica stale ad | MONITOR-thrash / epoch fight |
| H10 | `--apply` without `--local-sentinel` | Every sidecar heals at once |

`make e2e-hazards` walks H1–H10 in the lab.

## Several master names

One `--master-name` per process. Run another instance if you monitor
more than one name. A single process that juggles a list of masters is
backlog; do not pretend the current binary does it.
