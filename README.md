# redis-sentinel-reconciler

**Sentinel's advertised master must be the Redis that accepts writes.**

`SENTINEL get-master-addr-by-name` is the address clients write to. When it
still names a **dead master**, an **old master after failover**, or a node
stuck on an **equal config-epoch**, they write into a hole. This process
runs next to each Sentinel, finds who actually accepts `SET`, and heals
**that pointer** through Sentinel's own API. It does not edit
`sentinel.conf`, does not restart Sentinel, and does not send `REPLICAOF`.

It speaks the Sentinel wire protocol (Redis and Valkey). Drop it onto an
existing cluster (systemd `.deb`) or next to Bitnami/in-cluster Sentinel
(Helm or an in-pod sidecar). It scrapes as `/metrics` (`:9123`).

Install: [docs/install.md](docs/install.md) · Flags:
[docs/configuration.md](docs/configuration.md) · When it pages:
[docs/operations.md](docs/operations.md) · Where to talk about it:
[docs/outreach.md](docs/outreach.md)

## What operators usually do (and why it is a kludge)

The data plane is often fine. **Sentinel's advertisement is stale.** Today
that gets "fixed" by bouncing the control plane:

| Kludge | What actually happens |
|--------|------------------------|
| `systemctl restart redis-sentinel` | Reboot of the pointer. In-memory view vs `sentinel.conf`; clients reconnect; the lie can reload from conf. |
| `sed` / `vi` `sentinel.conf` then restart | Same reboot, plus you fight Hello / epoch. Redis already rewrites that file itself after a real failover. |
| `SENTINEL RESET *` | Forgets peers and monitors. Nuclear. |
| Reboot the VM / recreate the pod | Hope the new process comes up with a better MONITOR line. |
| Write-probe in *your* app | Other clients still trust `get-master-addr-by-name`. The lie stays. |

This sidecar attaches to a **running** Sentinel. Heal is `REMOVE`+`MONITOR`
(and `FAILOVER` only when that cannot dual the live writable). No conf
edit. No Sentinel restart. Dual writable → it **refuses** and pages; you
or Sentinel still `REPLICAOF`.

## Phrases this is (search / GitHub)

Stale Sentinel master · Sentinel still pointing to old master ·
`get-master-addr-by-name` wrong · advertised master is down · clients
writing to dead Redis after failover · equal config-epoch different IP ·
`sentinel.conf` MONITOR stuck · Valkey Sentinel wrong master ·
`-failover-abort-no-good-slave` leftover ads · Kubernetes Sentinel old
master IP after pod recycle

## Install — two addresses, then start

Every process needs **both**:

| Setting | Meaning |
|---------|---------|
| `SENTINEL_ADDR` | Sentinel on **this** host (or this pod), `host:26379` |
| `REDIS_ADDRS` | **Every** Redis/Valkey data node that can become master, port **6379** |

Empty → exit 2, unit does not start. Leave `APPLY=false` until ticks look
quiet, then `APPLY=true` on each sidecar.

### systemd: `.deb` (Debian / Ubuntu)

```bash
curl -fsSL -o rsr.deb \
  https://github.com/vpnmesh/redis-sentinel-reconciler/releases/latest/download/redis-sentinel-reconciler_linux_amd64.deb
sudo dpkg -i rsr.deb
sudo editor /etc/default/redis-sentinel-reconciler   # SENTINEL_ADDR, REDIS_ADDRS
sudo systemctl enable --now redis-sentinel-reconciler
journalctl -u redis-sentinel-reconciler -f
```

Tarball + `install-systemd.sh`: [docs/install.md](docs/install.md).

### Quick start: Docker Hub image + Helm

Image: [`vpnmesh/redis-sentinel-reconciler`](https://hub.docker.com/r/vpnmesh/redis-sentinel-reconciler)
(each `v*` tag, plus `:latest`; [Hub setup](docs/docker-hub.md)). Chart:
`oci://ghcr.io/vpnmesh/charts/redis-sentinel-reconciler` — it already
points at that Hub repo; empty `image.tag` follows the chart version.

Smoke the binary (observe-only; needs `SENTINEL_ADDR` + `REDIS_ADDRS` to
stay up):

```bash
docker pull vpnmesh/redis-sentinel-reconciler:latest
docker run --rm vpnmesh/redis-sentinel-reconciler:latest -h
```

**Helm** — DaemonSet on the node (`hostNetwork`). Leave `apply` false
until ticks look quiet:

```bash
helm install rsr oci://ghcr.io/vpnmesh/charts/redis-sentinel-reconciler \
  --set sentinelAddr=db-n1.example.com:26379 \
  --set 'redisAddrs={db-n1.example.com:6379,db-n2.example.com:6379,db-n3.example.com:6379}'
```

From this git tree (untagged chart pulls `:latest`):

```bash
helm install rsr deploy/helm/redis-sentinel-reconciler \
  --set sentinelAddr=db-n1.example.com:26379 \
  --set 'redisAddrs={db-n1.example.com:6379,db-n2.example.com:6379,db-n3.example.com:6379}'
```

Pin a release with `--version 0.1.4` (OCI) or `--set image.tag=0.1.4`.
STS / ordinal pairing: [docs/install.md](docs/install.md) ·
[lab/kind](lab/kind/README.md).

**Bitnami in-pod sidecar** (same netns as Sentinel, `127.0.0.1:26379`) —
merge [deploy/examples/bitnami-redis-sidecar.yaml](deploy/examples/bitnami-redis-sidecar.yaml)
into the Bitnami Redis chart. Do **not** also install our chart on that
namespace or you run two healers per Sentinel.

Kind lab still builds a **local** image (`make kind-up`), not Hub.

## Metrics

`--metrics-addr=:9123` → `/metrics`. Gauges: `diverged`, `would_heal`,
`writable_masters`. Counters: `diverge_total`, `heal_*`,
`alert_dual_master_total`. Alert rules:
[deploy/observability/prometheus-alerts.yaml](deploy/observability/prometheus-alerts.yaml).
Helper: `scripts/dwell-status.sh http://127.0.0.1:9123/metrics`.

## Safety (honest)

| Does | Does not |
|------|----------|
| Heal local Sentinel ads toward the unique writable Redis | Send `REPLICAOF` / pick a winner on dual |
| Refuse 0 or ≥2 writables, partition islands, in-flight failover | Rewrite `sentinel.conf` (logs `conf_fallback_needed`) |
| Export Prometheus metrics | Sit in the client path — apps should still write-probe |

One `--master-name` per process. Several names → several processes.

`writer` is a lab load generator. Don't put it on a cluster.

Dry-run still writes a short-lived Redis key (`rsr:probe`). It does not
change Sentinel until `--apply`.

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
