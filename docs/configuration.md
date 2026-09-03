# Configuration

Flags and environment variables are the same knobs. A flag wins if you
pass it. Env names prefer `RSR_*`; the shorter names in the example file
(`SENTINEL_ADDR`, `REDIS_PASSWORD`, …) still work.

Booleans: `true` / `false` / `1` / `0` / `yes` / `no`. The old
`APPLY_FLAG=--apply` trick still enables apply; prefer `APPLY=true`.

`--local-sentinel` only means “heal this process’s first Sentinel”. It
does **not** supply an address.

## Config file (`--config`)

The packaged unit is:

```
ExecStart=/usr/bin/reconciler --config /etc/default/redis-sentinel-reconciler --local-sentinel
```

The file is `KEY=VALUE` (optional `export `, `#` comments). The process
reads it itself. `$`, `#`, spaces, and quotes in passwords stay literal.
Missing or unreadable file → exit 2 (unit fails). That is intentional:
systemd `EnvironmentFile=-…` used to swallow a parse error and start a
process with no `SENTINEL_ADDR`.

Precedence: **flag > process environment > `--config` file**.

Quote values that contain spaces:

```
REDIS_PASSWORD="p$a#ss word"
```

If you insist on a systemd `EnvironmentFile=` (no leading `-`), systemd
will still expand `$` (`$` → `$$`) and treat unquoted `#` as a comment.
Prefer `--config`.

## Required

| Flag | Env | Notes |
|------|-----|--------|
| `--sentinel-addr` | `RSR_SENTINEL_ADDR` / `SENTINEL_ADDR` | Local Sentinel. On TLS, use the DNS name on the certificate, not `127.0.0.1`. |
| `--master-name` | `RSR_MASTER_NAME` / `MASTER_NAME` | Sentinel monitor name (`mymaster` is the Redis default). |
| `--redis-addrs` | `RSR_REDIS_ADDRS` / `REDIS_ADDRS` | Every Redis/Valkey data node, **port 6379**. Required. The writable oracle is built from this list only. |

Without `--sentinel-addr` or `--redis-addrs` the process refuses to start.
Empty seeds used to mean “trust Sentinel advertisements as extra probe
targets”. Advertisements are the thing that lie.

Binary path in the package is `/usr/bin/reconciler`.

## Mode

| Flag | Env | Default |
|------|-----|---------|
| `--apply` | `RSR_APPLY` / `APPLY` | `false` (observe, log `would_heal`) |
| `--local-sentinel` | `RSR_LOCAL_SENTINEL` | `false` in the binary; always on in the packaged unit. Required with `--apply`. |
| `--once` | `RSR_ONCE` | `false` |
| `--interval` | `RSR_INTERVAL` / `INTERVAL` | `5s` (the env example uses `30s`) |
| `--interval-jitter` | `RSR_INTERVAL_JITTER` | `0.2` |
| `--metrics-addr` | `RSR_METRICS_ADDR` / `METRICS_ADDR` | empty (example uses `127.0.0.1:9123`) |

Ship observe-only. Turn on apply on one host after you have seen real
ticks, not because the lab went green.

## Auth

| Flag | Env |
|------|-----|
| `--redis-password` | `RSR_REDIS_PASSWORD` / `REDIS_PASSWORD` |
| `--sentinel-password` | `RSR_SENTINEL_PASSWORD` / `SENTINEL_PASSWORD` |
| `--redis-username` | `RSR_REDIS_USERNAME` / `REDIS_USERNAME` |
| `--sentinel-username` | `RSR_SENTINEL_USERNAME` / `SENTINEL_USERNAME` |
| `--sentinel-redis-username` | `RSR_SENTINEL_REDIS_USERNAME` / `SENTINEL_REDIS_USERNAME` |
| `--sentinel-redis-password` | `RSR_SENTINEL_REDIS_PASSWORD` / `SENTINEL_REDIS_PASSWORD` |

Empty username is Redis `default` (`AUTH password`).

Two credential planes:

| Who | Flags | Needs |
|-----|--------|--------|
| This process → Redis (ROLE, `SET rsr:probe`, heal lease) | `--redis-username` / `--redis-password` | Often `ROLE` (`@dangerous`) + `SET` on `rsr:*` |
| Sentinel → Redis (replication / master auth after MONITOR) | `--sentinel-redis-username` / `--sentinel-redis-password` | Whatever `sentinel monitor` uses (`sentinel` ACL user is typical: `+replicaof` `+role`, **not** `SET`) |

If `--sentinel-redis-*` are unset, MONITOR re-bind falls back to the probe Redis user/password. That is wrong when the probe user is `default`/`+@all` and Sentinel should use a tighter replication user.

After `REMOVE`+`MONITOR`, the process always re-binds `SENTINEL SET auth-user` / `auth-pass` from the Sentinel→Redis pair (or the probe fallback). ACL clusters break if only the password is restored.

Use a **dedicated sidecar user**, not the application user.

Redis (observe + write-probe) typically needs:

- `ROLE` (often in `@dangerous` on Redis 6/7 — grant it explicitly)
- `SET` / `GET` / `DEL` / `EXPIRE` on `rsr:*` (probe key `rsr:probe`, heal lease `rsr:heal-lease:*`)
- `INFO` (server/replication bits used in probes)

Sentinel needs enough `SENTINEL` subcommands for get-master-addr, master,
replicas, sentinels, and (only if you `--apply`) failover / remove /
monitor / reset / set. Exact ACL syntax varies by version — test it.

`requirepass` / `sentinel auth-pass` on the servers still work if you are
not on ACL yet.

## TLS

One TLS profile (CA, client cert, skip-verify) is used for both Redis and
Sentinel. SNI is **per dial**, from a clone of the tls.Config (no shared
`ServerName` race).

| Dial target | SNI |
|-------------|-----|
| Hostname (`db-n2.example.com:6379`) | that hostname |
| IP (`127.0.0.1:26379`) | `--tls-server-name` / `RSR_TLS_SERVER_NAME` if set, else empty |

`--tls-server-name` is **not** applied to hostname dials. One global name
cannot be correct for the local Sentinel on loopback and other nodes by
DNS. Prefer dialing the DNS name on the certificate for every target,
including the local Sentinel. Do not default `--local-sentinel` to
`127.0.0.1` on a TLS-only cluster.

| Flag | Env |
|------|-----|
| `--tls` | `RSR_TLS` |
| `--tls-ca-file` | `RSR_TLS_CA_FILE` / `TLS_CA_FILE` — PEM trust bundle |
| `--tls-server-name` | `RSR_TLS_SERVER_NAME` / `TLS_SERVER_NAME` — IP-only SNI fallback |
| `--tls-skip-verify` | `RSR_TLS_SKIP_VERIFY` |
| `--tls-cert` / `--tls-key` | `RSR_TLS_CERT` / `RSR_TLS_KEY` — client cert if Redis wants mTLS |

TLS 1.2 minimum. CA file, skip-verify, or a client cert without `--tls`
is a startup error.

`--tls-skip-verify` is for a first bring-up when you do not have the CA
on disk yet. Switch to `--tls-ca-file` once you do.

## Guards (leave the defaults)

| Flag | Default | Why |
|------|---------|-----|
| `--heal-cooldown` | `15m` | Do not heal in a loop. |
| `--heal-lease` | `true` | One apply at a time (`rsr:heal-lease:<name>` on the oracle). |
| `--equal-epoch-escalate` | `true` | Under equal-epoch, refuse MONITOR unless FAILOVER was skipped because the advertised node is a **live replica** (stale ad). That case MONITOR's the unique writable oracle. |
| `--min-reachable-redis` | `0` (auto: 2 if you listed ≥3 seeds) | Refuse apply from a tiny island. |
| `--skip-on-failover-in-progress` | `true` | Do not fight a stock election. |
| `--quorum` | `2` | Used only for `SENTINEL MONITOR` fallback. |
| `--heal-lease-ttl` | cooldown / 15m | |
| `--lease-holder` | hostname | |
| `--allow-global-apply` | `false` | Leave it off. |

## Metrics

`--metrics-addr` (example `127.0.0.1:9123`) serves Prometheus text at
`/metrics`. Counters are `*_total`, registered at 0, with `# HELP` / `# TYPE`.
Gauges `diverged`, `would_heal`, `writable_masters` are last-tick state.
Scrape does not increment. See [operations.md](operations.md).

## Example env file

See [`deploy/systemd/redis-sentinel-reconciler.default`](../deploy/systemd/redis-sentinel-reconciler.default).

```bash
SENTINEL_ADDR=db-n1.example.com:26379
MASTER_NAME=mymaster
REDIS_ADDRS=db-n1.example.com:6379,db-n2.example.com:6379,db-n3.example.com:6379
APPLY=false
INTERVAL=30s
METRICS_ADDR=127.0.0.1:9123
RSR_TLS=true
RSR_TLS_CA_FILE=/etc/redis/ca.pem
REDIS_USERNAME=rsr
REDIS_PASSWORD="p$a#ss word"
SENTINEL_REDIS_USERNAME=sentinel
SENTINEL_REDIS_PASSWORD="..."
SENTINEL_USERNAME=rsr
SENTINEL_PASSWORD="..."
```
