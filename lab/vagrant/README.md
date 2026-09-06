# lab/vagrant: bare-metal-like Sentinel lab (Redis **or** Valkey)

See **[PLAN.md](PLAN.md)** (binding). Engine soft-dual: same reconciler; `ENGINE=redis|valkey`.

```bash
# from redis-sentinel-reconciler/
make vagrant-up                    # CLUSTER_N=5 ENGINE=redis
make vagrant-smoke
CLUSTER_N=3 make vagrant-up
CLUSTER_N=3 make vagrant-a09       # sticky wrong MONITOR C0 vs C2
CLUSTER_N=3 make vagrant-a01       # old master return
CLUSTER_N=3 make vagrant-pkg       # dpkg -i shipped .deb on node-1 (empty config fails, then starts)

# Valkey data-plane (bins fetched once from valkey/valkey:8)
make vagrant-engine-bins ENGINE=valkey
ENGINE=valkey CLUSTER_N=3 make vagrant-up
ENGINE=valkey CLUSTER_N=3 make vagrant-smoke
```

Provider: **Docker** + systemd image:
- `ENGINE=redis`: `jrei/systemd-ubuntu:22.04`
- `ENGINE=valkey`: `jrei/systemd-ubuntu:24.04` (Valkey bins need glibc 2.38+)

Provision via `scripts/provision-all.sh` (`docker exec`). Vagrant SSH to systemd images is flaky.
After chaos/provision: `make vagrant-restore` (node-1 master + ads).

`make vagrant-pkg` builds `dist/*.deb` on the host and `dpkg -i` on **node-1**. It checks that an unedited `/etc/default` exits 2 with the SENTINEL_ADDR / REDIS_ADDRS help, then fills those two and expects the packaged unit (`/usr/bin/reconciler --config`) to become active. The lab overlay unit is restored afterwards so A01/A09 still work.
