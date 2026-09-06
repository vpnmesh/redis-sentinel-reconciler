# Configuration

The same setting can be a **flag**, an **environment variable**, or a
line in the `--config` file:

`--sentinel-addr` = `SENTINEL_ADDR` = `RSR_SENTINEL_ADDR`

`--foo-bar` is always `FOO_BAR` and `RSR_FOO_BAR`. A flag wins if you
pass it. Then process environment. Then the `--config` file.

The file also accepts `sentinel-addr=` (hyphens). Booleans: `true` /
`false` / `1` / `0` / `yes` / `no`.

`--local-sentinel` means “only heal this process’s first Sentinel”. It
does not fill in an address. It is **on** by default. `--apply` with
`--local-sentinel=false` is refused unless you also pass
`--allow-global-apply`.

## What you must set

Without these the process prints a short explanation and exits (code 2).
It does not guess `127.0.0.1`.

Packaged unit:

```
ExecStart=/usr/bin/reconciler --config /etc/default/redis-sentinel-reconciler --local-sentinel
```

| Setting | What to put |
|---------|-------------|
| `SENTINEL_ADDR` | The Sentinel **on this host**, `host:26379`. On TLS, the DNS name on the certificate, not `127.0.0.1`. |
| `REDIS_ADDRS` | **Every** Redis/Valkey data node that can become master, port **6379**. The whole cluster, not only this host. |
| `MASTER_NAME` | Sentinel monitor name (`mymaster` if you did not change it). |

`REDIS_ADDRS` is the list this process probes to see who actually
accepts writes. Sentinel’s own advertisement is what we check against,
not the source of truth. If you list only the local Redis, a master on
another host is invisible.

Then, if the cluster uses them: `REDIS_USERNAME` / `REDIS_PASSWORD`,
`SENTINEL_USERNAME` / `SENTINEL_PASSWORD`, `TLS=true` + `TLS_CA_FILE`.

Leave `APPLY=false` until you have watched a few ticks. The example
`METRICS_ADDR` is `127.0.0.1:9123`. Interval, cooldown, and lease
already have production defaults; copy those into the file only if you
need to change one.

Binary path in the package is `/usr/bin/reconciler`.

Sample after you fill it: [`deploy/systemd/redis-sentinel-reconciler.default`](../deploy/systemd/redis-sentinel-reconciler.default).

```bash
SENTINEL_ADDR=db-n1.example.com:26379
MASTER_NAME=mymaster
REDIS_ADDRS=db-n1.example.com:6379,db-n2.example.com:6379,db-n3.example.com:6379
APPLY=false
METRICS_ADDR=127.0.0.1:9123
TLS=true
TLS_CA_FILE=/etc/redis/ca.pem
REDIS_USERNAME=rsr
REDIS_PASSWORD="p$a#ss word"
SENTINEL_USERNAME=rsr
SENTINEL_PASSWORD="..."
```

The shipped file leaves `SENTINEL_ADDR=` and `REDIS_ADDRS=` empty on
purpose: an unedited install will not start, instead of dialing a
placeholder host.

## Config file (`--config`)

The process reads `KEY=VALUE` itself (optional `export `, `#` comments).
`$`, `#`, spaces, and quotes in passwords stay literal. If the file is
missing or unreadable, exit 2. (A systemd `EnvironmentFile=-...` used to
swallow that and start with an empty `SENTINEL_ADDR`.)

`--config` / `-config` / `CONFIG=` / `RSR_CONFIG=` are the same path
(the flag wins).

If you still want systemd `EnvironmentFile=` (no leading `-`), systemd
will expand `$` (`$` becomes `$$`) and treat unquoted `#` as a comment.
Prefer `--config`.

## Auth

| Knob |
|------|
| `--redis-password` / `REDIS_PASSWORD` |
| `--sentinel-password` / `SENTINEL_PASSWORD` |
| `--redis-username` / `REDIS_USERNAME` |
| `--sentinel-username` / `SENTINEL_USERNAME` |
| `--sentinel-redis-username` / `SENTINEL_REDIS_USERNAME` |
| `--sentinel-redis-password` / `SENTINEL_REDIS_PASSWORD` |

Empty username is Redis `default` (`AUTH password`).

Two credential planes:

| Who | Knobs | Needs |
|-----|--------|--------|
| This process to Redis (`ROLE`, `SET rsr:probe`, heal lease) | `--redis-username` / `--redis-password` | Often `ROLE` (`@dangerous`) + `SET` on `rsr:*` |
| Sentinel to Redis (replication after MONITOR) | `--sentinel-redis-username` / `--sentinel-redis-password` | Whatever `sentinel monitor` uses (typical `sentinel` ACL user: `+replicaof` `+role`, not `SET`) |

If `--sentinel-redis-*` are unset, MONITOR re-bind uses the probe Redis
user/password. That is the wrong user when the probe account is
`default` / `+@all` and Sentinel should use a tighter replication user.

After `REMOVE`+`MONITOR`, the process always re-binds `SENTINEL SET
auth-user` / `auth-pass` from the Sentinel-to-Redis pair (or the probe
fallback). ACL clusters break if only the password is restored.

Use a **dedicated sidecar user**, not the application user.

Redis (observe + write-probe) typically needs:

- `ROLE` (often in `@dangerous` on Redis 6/7; grant it explicitly)
- `SET` / `GET` / `DEL` / `EXPIRE` on `rsr:*` (probe key `rsr:probe`, heal lease `rsr:heal-lease:*`)
- `INFO` (server/replication bits used in probes)

Sentinel needs enough `SENTINEL` subcommands for get-master-addr, master,
replicas, sentinels, and (only if you `--apply`) failover / remove /
monitor / reset / set. Exact ACL syntax varies by version. Test it.

`requirepass` / `sentinel auth-pass` on the servers still work if you are
not on ACL yet.

## TLS

One TLS profile (CA, client cert, skip-verify) is used for both Redis and
Sentinel. SNI is **per dial**.

| Dial target | SNI |
|-------------|-----|
| Hostname (`db-n2.example.com:6379`) | that hostname |
| IP (`127.0.0.1:26379`) | `--tls-server-name` / `TLS_SERVER_NAME` if set, else empty |

`--tls-server-name` is not applied to hostname dials. Prefer dialing
the DNS name on the certificate for every target, including the local
Sentinel.

| Knob |
|------|
| `--tls` / `TLS` |
| `--tls-ca-file` / `TLS_CA_FILE` |
| `--tls-server-name` / `TLS_SERVER_NAME` (IP-only SNI fallback) |
| `--tls-skip-verify` / `TLS_SKIP_VERIFY` |
| `--tls-cert` / `--tls-key` (`TLS_CERT` / `TLS_KEY`, also `TLS_CERT_FILE` / `TLS_KEY_FILE`) |

TLS 1.2 minimum. CA file, skip-verify, or a client cert without `--tls`
is a startup error. `--tls-skip-verify` is for a first bring-up; switch
to `--tls-ca-file` once you have the CA.

## Mode and metrics

| Knob | Default |
|------|---------|
| `--apply` / `APPLY` | `false` (observe, log `would_heal`) |
| `--local-sentinel` / `LOCAL_SENTINEL` | `true` |
| `--once` / `ONCE` | `false` |
| `--interval` / `INTERVAL` | `30s` |
| `--metrics-addr` / `METRICS_ADDR` | empty (example uses `127.0.0.1:9123`) |

The old `APPLY_FLAG=--apply` spelling still enables apply; prefer `APPLY=true`.

`--metrics-addr` serves Prometheus text at `/metrics`. Counters are
`*_total`, registered at 0, with `# HELP` / `# TYPE`. Gauges `diverged`,
`would_heal`, `writable_masters` are last-tick state. Scrape does not
increment. See [operations.md](operations.md).

## Advanced (leave the defaults)

`reconciler -h` lists every flag. These already match a sidecar on a
real cluster:

| Knob | Default | Why |
|------|---------|-----|
| `--heal-cooldown` | `15m` | Do not heal in a loop. |
| `--heal-lease` | `true` | One apply at a time (`rsr:heal-lease:<name>` on the writable Redis). |
| `--equal-epoch-escalate` | `true` | Under equal-epoch, refuse MONITOR unless FAILOVER was skipped because the advertised node is a **live replica**. In that case MONITOR points Sentinel at the unique writable Redis. |
| `--min-reachable-redis` | `0` (auto: 2 if you listed 3 or more seeds) | Refuse apply from a tiny island. |
| `--skip-on-failover-in-progress` | `true` | Do not fight a stock election. |
| `--interval-jitter` | `0.2` | |
| `--quorum` | `2` | Used only for `SENTINEL MONITOR` fallback. |
| `--heal-lease-ttl` | cooldown / 15m | |
| `--lease-holder` | hostname | |
| `--allow-global-apply` | `false` | Leave it off. |
| `--sentinel-from-ordinal-prefix` / `--sentinel-from-ordinal-suffix` | empty | Kubernetes StatefulSet: with `POD_NAME`, `SENTINEL_ADDR` becomes `prefix` + ordinal + `suffix` (scratch image has no shell). |
