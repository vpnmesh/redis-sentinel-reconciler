# redis-sentinel-reconciler

Redis Sentinel sometimes advertises a master that is already dead, or one
that lost an election and never caught up. Clients take that address at
face value and write into a hole.

This process runs next to each Sentinel. It probes the Redis nodes you
give it, decides who actually accepts writes, and compares that to the
local `SENTINEL get-master-addr-by-name`. By default it only logs and
exports metrics. Pass `--apply` if you want it to heal the advertisement
with Sentinel's own `FAILOVER` / `REMOVE`+`MONITOR` path.

It speaks the Sentinel wire protocol, so Redis and Valkey both work.

Install and flags: [docs/install.md](docs/install.md), [docs/configuration.md](docs/configuration.md).
What to do when it pages: [docs/operations.md](docs/operations.md).

## Install (linux/amd64)

One sidecar per Sentinel host. Three steps: install the package, fill two
addresses, start the unit. Leave `APPLY=false` until you have watched ticks.

`SENTINEL_ADDR` is the Sentinel on **this** host. `REDIS_ADDRS` is **every**
Redis/Valkey data node that can become master (port 6379), not only the
local one.

### Debian / Ubuntu

```bash
curl -fsSL -o rsr.deb \
  https://github.com/vpnmesh/redis-sentinel-reconciler/releases/latest/download/redis-sentinel-reconciler_linux_amd64.deb
sudo dpkg -i rsr.deb
sudo editor /etc/default/redis-sentinel-reconciler   # SENTINEL_ADDR, REDIS_ADDRS
sudo systemctl enable --now redis-sentinel-reconciler
journalctl -u redis-sentinel-reconciler -f
```

If those two are still empty, the unit fails immediately with a short
explanation (exit 2). That is expected.

### Tarball (any systemd amd64)

```bash
curl -fsSL -o rsr.tgz \
  https://github.com/vpnmesh/redis-sentinel-reconciler/releases/latest/download/redis-sentinel-reconciler_linux_amd64.tar.gz
tar -xzf rsr.tgz
cd redis-sentinel-reconciler_*_linux_amd64
sudo ./install-systemd.sh
sudo editor /etc/default/redis-sentinel-reconciler
sudo systemctl enable --now redis-sentinel-reconciler
```

Flags, env, and that file are the same knobs (`--apply` = `APPLY=true`).
Dial the **DNS name on the certificate** (port 6379 for Redis, 26379 for
Sentinel). Helm and from-source: [docs/install.md](docs/install.md).

When every sidecar looks quiet, set `APPLY=true` on each host and
`systemctl restart redis-sentinel-reconciler`. Defaults heal a stale
live-replica advertisement with `REMOVE`+`MONITOR` onto the node that
accepts writes. Two writable nodes still refuse both FAILOVER and MONITOR.

`writer` is a lab load generator. Don't put it on a cluster.

Dry-run still writes a short-lived Redis key (`rsr:probe`) so it can tell
who is writable. It does not change Sentinel until `--apply`.

## Safety

If there are zero writable Redis nodes, or two or more, the process
refuses to heal. Same if it can only see a partition island, if a
failover is already in progress, or if `--apply` is used with
`--local-sentinel=false`. Details are in [docs/operations.md](docs/operations.md).

It never sends `REPLICAOF`. Demoting a returning old master is still
Sentinel's job. It also does not rewrite `sentinel.conf`; if the API path
fails it logs `conf_fallback_needed` and stops.

Apps should keep discovering via Sentinel and still write-probe. This
sidecar is not in the client path.

One `--master-name` per process. Several names means several processes.

## Lab

Docker Compose lab (5 Redis + 5 Sentinel) lives under [`lab/`](lab/README.md):

```bash
make e2e
```

Kind (Bitnami Redis 25.5.3 + our chart, local image): [lab/kind](lab/kind/README.md).

```bash
make kind-e2e
make kind-chaos
make kind-stress
```

## License

SPDX-License-Identifier: Apache-2.0

Copyright 2026 Vyskrebtsev Aleksandr, IE.

You may run, modify, and ship this sidecar under the Apache License 2.0.
See [LICENSE](LICENSE) and [NOTICE](NOTICE). Patches: [CONTRIBUTING.md](CONTRIBUTING.md).

VpnMesh is a trademark of Vyskrebtsev Aleksandr, IE. The license covers
the software, not the name.
