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

Release artifacts are a tarball and a Debian package. Other GOOS/GOARCH
builds are not published yet.

```bash
# Debian / Ubuntu
sudo dpkg -i redis-sentinel-reconciler_*_amd64.deb

# or the tarball
tar -xzf redis-sentinel-reconciler_*_linux_amd64.tar.gz
sudo install -m 0755 reconciler /usr/bin/reconciler
sudo install -m 0644 systemd/redis-sentinel-reconciler.service \
  /lib/systemd/system/redis-sentinel-reconciler.service
sudo install -m 0640 systemd/redis-sentinel-reconciler.default \
  /etc/default/redis-sentinel-reconciler
```

From source:

```bash
go test ./...
go build -o reconciler ./cmd/reconciler
```

`writer` is a lab load generator. Don't put it on a cluster.

## Run

One process per Sentinel host. Dial the **DNS name on the certificate**
for the local Sentinel and for every Redis seed (port 6379, not 26379).
`--local-sentinel` does not imply `127.0.0.1`.

Leave `APPLY=false` until you have watched it. The unit runs
`/usr/bin/reconciler --config /etc/default/redis-sentinel-reconciler --local-sentinel`.
With stock defaults, `APPLY=true` on **every** sidecar is the intended
heal: a stale local ad of a live replica is `REMOVE`+`MONITOR` onto the
unique writable oracle (no `sentinel.conf` rewrite, no per-host escalate
off). Dual writable still refuses both FAILOVER and MONITOR.

```bash
sudo systemctl enable --now redis-sentinel-reconciler
journalctl -u redis-sentinel-reconciler -f
```

Dry-run still writes a short-lived Redis key (`rsr:probe`) so it can tell
who is writable. It does not change Sentinel until `--apply`.

## Safety

If there are zero writable Redis nodes, or two or more, the process
refuses to heal. Same if it can only see a partition island, if a
failover is already in progress, or if `--apply` is used without
`--local-sentinel`. Details are in [docs/operations.md](docs/operations.md).

It never sends `REPLICAOF`. Demoting a returning old master is still
Sentinel's job. It also does not rewrite `sentinel.conf`; if the API path
fails it logs `conf_fallback_needed` and stops.

Apps should keep discovering via Sentinel **and** write-probe. This
binary is not a client library.

One `--master-name` per process. Several names means several processes.

## Lab

Docker Compose lab (5 Redis + 5 Sentinel) lives under [`lab/`](lab/README.md):

```bash
make e2e
```
