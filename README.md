# redis-sentinel-reconciler

**Sentinel's advertised master must be the Redis that accepts writes.**

`SENTINEL get-master-addr-by-name` is the address clients write to. When it
still names a dead master, an old master after failover, or a node stuck
on an equal config-epoch, they write into a hole. This process runs next
to each Sentinel, finds who actually accepts `SET`, and heals that
pointer through Sentinel's own API. It does not edit `sentinel.conf`,
does not restart Sentinel, and does not send `REPLICAOF`.

It speaks the Sentinel wire protocol (Redis and Valkey). One sidecar per
Sentinel. Metrics at `/metrics` (`:9123`).

| | |
|------|------|
| systemd `.deb` | [docs/install-systemd.md](docs/install-systemd.md) |
| Docker image + Helm | [docs/install-docker-helm.md](docs/install-docker-helm.md) |
| Flags | [docs/configuration.md](docs/configuration.md) |
| When it pages | [docs/operations.md](docs/operations.md) |
| Where to talk about it | [docs/outreach.md](docs/outreach.md) |
| Docker Hub | https://hub.docker.com/r/vpnmesh/redis-sentinel-reconciler |

Every process needs `SENTINEL_ADDR` (Sentinel on this host, `host:26379`)
and `REDIS_ADDRS` (every data node that can become master, port 6379).
Empty exits 2. One reconciler per Sentinel. Leave apply off until ticks
look quiet.

## What operators usually do (and why it is a kludge)

The data plane is often fine. Sentinel's advertisement is stale. Today
that gets "fixed" by bouncing the control plane:

| Kludge | What actually happens |
|--------|------------------------|
| `systemctl restart redis-sentinel` | Reboot of the pointer. In-memory view vs `sentinel.conf`; clients reconnect; the lie can reload from conf. |
| `sed` / `vi` `sentinel.conf` then restart | Same reboot, plus you fight Hello / epoch. Redis already rewrites that file itself after a real failover. |
| `SENTINEL RESET *` | Forgets peers and monitors. Nuclear. |
| Reboot the VM / recreate the pod | Hope the new process comes up with a better MONITOR line. |
| Write-probe in *your* app | Other clients still trust `get-master-addr-by-name`. The lie stays. |

This sidecar attaches to a running Sentinel. Heal is `REMOVE`+`MONITOR`
(and `FAILOVER` only when that cannot dual the live writable). No conf
edit. No Sentinel restart. Dual writable: it refuses and pages; you or
Sentinel still `REPLICAOF`.

## Phrases this is (search / GitHub)

Stale Sentinel master, Sentinel still pointing to old master,
`get-master-addr-by-name` wrong, advertised master is down, clients
writing to dead Redis after failover, equal config-epoch different IP,
`sentinel.conf` MONITOR stuck, Valkey Sentinel wrong master,
`-failover-abort-no-good-slave` leftover ads, Kubernetes Sentinel old
master IP after pod recycle.

## Metrics

`--metrics-addr=:9123` serves `/metrics`. Gauges: `diverged`, `would_heal`,
`writable_masters`. Counters: `diverge_total`, `heal_*`,
`alert_dual_master_total`. Alert rules:
[deploy/observability/prometheus-alerts.yaml](deploy/observability/prometheus-alerts.yaml).
Helper: `scripts/dwell-status.sh http://127.0.0.1:9123/metrics`.

Dry-run still writes a short-lived Redis key (`rsr:probe`). It does not
change Sentinel until `--apply`. `writer` is a lab load generator; don't
put it on a cluster.

## Lab

```bash
make e2e          # Compose 5+5, --apply sidecars
make kind-e2e     # Bitnami Redis 25.5.3 + our chart (local image)
```

## License

SPDX-License-Identifier: Apache-2.0

Copyright 2026 Vyskrebtsev Aleksandr, IE.

[LICENSE](LICENSE) · [NOTICE](NOTICE) · [CONTRIBUTING.md](CONTRIBUTING.md)

VpnMesh is a trademark of Vyskrebtsev Aleksandr, IE. The license covers
the software, not the name.
