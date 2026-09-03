# Configuration

Flags and environment variables are the same knobs. A flag wins if you
pass it. Env names prefer `RSR_*`; the shorter names in the systemd env
file (`SENTINEL_ADDR`, `REDIS_PASSWORD`, …) still work.

Booleans: `true` / `false` / `1` / `0` / `yes` / `no`. The old
`APPLY_FLAG=--apply` trick still enables apply; prefer `APPLY=true`.

systemd: put secrets in `/etc/default/redis-sentinel-reconciler`. The
unit only adds `--local-sentinel`, so passwords do not show up in `ps`.

## Required

| Flag | Env | Notes |
|------|-----|--------|
| `--sentinel-addr` | `RSR_SENTINEL_ADDR` / `SENTINEL_ADDR` | Usually `127.0.0.1:26379` on a sidecar. Comma-separated list is allowed. |
| `--master-name` | `RSR_MASTER_NAME` / `MASTER_NAME` | Sentinel monitor name (`mymaster` is the Redis default). |
| `--redis-addrs` | `RSR_REDIS_ADDRS` / `REDIS_ADDRS` | Every Redis/Valkey data node, **port 6379**. The writable-oracle is built from this list only. |

Without `--sentinel-addr` the process refuses to start. Without
`--redis-addrs` it will still run and start trusting Sentinel
advertisements as extra probe targets — don't do that in production.
Advertisements are the thing that lie.

## Mode

| Flag | Env | Default |
|------|-----|---------|
| `--apply` | `RSR_APPLY` / `APPLY` | `false` (observe, log `would_heal`) |
| `--local-sentinel` | `RSR_LOCAL_SENTINEL` | `false` in the binary; always on in the packaged unit. Required with `--apply`. |
| `--once` | `RSR_ONCE` | `false` |
| `--interval` | `RSR_INTERVAL` / `INTERVAL` | `5s` (the env example uses `30s`) |
| `--interval-jitter` | `RSR_INTERVAL_JITTER` | `0.2` |
| `--metrics-addr` | `RSR_METRICS_ADDR` / `METRICS_ADDR` | empty (set e.g. `127.0.0.1:9090`) |

Ship observe-only. Turn on apply on one host after you have seen real
ticks, not because the lab went green.

## Auth

| Flag | Env |
|------|-----|
| `--redis-password` | `RSR_REDIS_PASSWORD` / `REDIS_PASSWORD` |
| `--sentinel-password` | `RSR_SENTINEL_PASSWORD` / `SENTINEL_PASSWORD` |
| `--redis-username` | `RSR_REDIS_USERNAME` / `REDIS_USERNAME` |
| `--sentinel-username` | `RSR_SENTINEL_USERNAME` / `SENTINEL_USERNAME` |

Empty username is Redis `default` (`AUTH password`). After a
`REMOVE`+`MONITOR` heal, the process re-binds `SENTINEL SET <name> auth-pass`
when `--redis-password` is set, because Sentinel drops `auth-*` on REMOVE.

A tight ACL user is enough: `ROLE`, `SET`/`GET` on `rsr:*`, `INFO`, and
the `SENTINEL` subcommands you actually need. Exact ACL syntax varies by
Redis version — test it.

`requirepass` / `sentinel auth-pass` on the servers still work if you are
not on ACL yet.

## TLS

One TLS profile is used for both Redis and Sentinel. If the cluster
speaks TLS and you omit `--tls`, every tick will fail to dial.

| Flag | Env |
|------|-----|
| `--tls` | `RSR_TLS` |
| `--tls-ca-file` | `RSR_TLS_CA_FILE` / `TLS_CA_FILE` — PEM trust bundle, one or more certs |
| `--tls-server-name` | `RSR_TLS_SERVER_NAME` / `TLS_SERVER_NAME` |
| `--tls-skip-verify` | `RSR_TLS_SKIP_VERIFY` |
| `--tls-cert` / `--tls-key` | `RSR_TLS_CERT` / `RSR_TLS_KEY` — client cert if Redis wants mTLS |

TLS 1.2 minimum. CA file, skip-verify, or a client cert without `--tls`
is a startup error.

When the sidecar dials `127.0.0.1` but the certificate is issued for the
machine hostname, set `--tls-server-name` to that hostname. Otherwise Go
verifies against `127.0.0.1` and fails.

`--tls-skip-verify` is for a first bring-up when you do not have the CA
on disk yet. Switch to `--tls-ca-file` once you do.

## Guards (leave the defaults)

| Flag | Default | Why |
|------|---------|-----|
| `--heal-cooldown` | `15m` | Do not heal in a loop. |
| `--heal-lease` | `true` | One apply at a time (`rsr:heal-lease:<name>` on the oracle). |
| `--equal-epoch-escalate` | `true` | Do not `MONITOR`-thrash when epochs are equal and FAILOVER is unsafe. |
| `--min-reachable-redis` | `0` (auto: 2 if you listed ≥3 seeds) | Refuse apply from a tiny island. |
| `--skip-on-failover-in-progress` | `true` | Do not fight a stock election. |
| `--quorum` | `2` | Used only for `SENTINEL MONITOR` fallback. |
| `--heal-lease-ttl` | cooldown / 15m | |
| `--lease-holder` | hostname | |
| `--allow-global-apply` | `false` | Leave it off. |

## Example env file

See [`deploy/systemd/redis-sentinel-reconciler.default`](../deploy/systemd/redis-sentinel-reconciler.default).

```bash
SENTINEL_ADDR=127.0.0.1:26379
MASTER_NAME=mymaster
REDIS_ADDRS=10.0.0.1:6379,10.0.0.2:6379,10.0.0.3:6379
APPLY=false
INTERVAL=30s
METRICS_ADDR=127.0.0.1:9090
RSR_TLS=true
RSR_TLS_CA_FILE=/etc/redis/ca.pem
RSR_TLS_SERVER_NAME=db-n1.example.net
REDIS_PASSWORD=...
SENTINEL_PASSWORD=...
```
