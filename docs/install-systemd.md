# Install: systemd

One sidecar per Sentinel host. Builds are linux/amd64: a `.deb` and a
`.tar.gz` on each GitHub Release. Stable names work with
`/latest/download/` (no version in the URL).

The binary is `/usr/bin/reconciler`.

Fill both before you enable the unit:

| Setting | What |
|---------|------|
| `SENTINEL_ADDR` | Sentinel on this host, `host:26379` |
| `REDIS_ADDRS` | Every Redis/Valkey data node that can become master, port 6379 (the whole cluster, not only this host) |

`MASTER_NAME=mymaster` is already set. Leave `APPLY=false` until you have
watched ticks. On TLS, dial the DNS name on the certificate, not
`127.0.0.1`. Flags: [configuration.md](configuration.md).

## Debian / Ubuntu

```bash
curl -fsSL -o rsr.deb \
  https://github.com/vpnmesh/redis-sentinel-reconciler/releases/latest/download/redis-sentinel-reconciler_linux_amd64.deb
sudo dpkg -i rsr.deb
sudo editor /etc/default/redis-sentinel-reconciler
sudo systemctl enable --now redis-sentinel-reconciler
journalctl -u redis-sentinel-reconciler -f
```

Older tags only have
`redis-sentinel-reconciler_<version>_amd64.deb` on the
[Releases](https://github.com/vpnmesh/redis-sentinel-reconciler/releases)
page. Use that until a tag with the stable name lands.

The package drops:

| Path | What |
|------|------|
| `/usr/bin/reconciler` | binary |
| `/lib/systemd/system/redis-sentinel-reconciler.service` | unit (`--config` + `--local-sentinel`) |
| `/etc/default/redis-sentinel-reconciler` | config (the process parses it) |

It creates a `redis` system user if needed. It does not start the unit.
Empty `SENTINEL_ADDR` / `REDIS_ADDRS` fail the unit (exit 2) instead of
probing the wrong place.

Removing the package stops the unit. The env file stays until `apt purge`.

## Tarball (any systemd linux/amd64)

```bash
curl -fsSL -o rsr.tgz \
  https://github.com/vpnmesh/redis-sentinel-reconciler/releases/latest/download/redis-sentinel-reconciler_linux_amd64.tar.gz
tar -xzf rsr.tgz
cd redis-sentinel-reconciler_*_linux_amd64
sudo ./install-systemd.sh
sudo editor /etc/default/redis-sentinel-reconciler
sudo systemctl enable --now redis-sentinel-reconciler
```

`install-systemd.sh` copies the binary and unit, writes the default file
only if it is missing, creates the `redis` user when `adduser` exists,
and runs `daemon-reload`. It does not enable the unit.

## From source

```bash
go test ./...
go build -o reconciler ./cmd/reconciler
sudo BIN="$PWD/reconciler" ./scripts/install-systemd.sh
```

Or `make dist` for a tarball and `.deb` into `dist/` (`VERSION` defaults
to `git describe` with a leading `v` stripped). Needs Go 1.23+ and
`dpkg-deb` for the `.deb`.

`reconciler --version` prints the stamp. `reconciler -h` must list
`-tls`, `-redis-username`, `-sentinel-username`. If it does not, the
binary is stale.

Lab check of the Debian path: `CLUSTER_N=3 make vagrant-pkg` (after
`make vagrant-up`). See [lab/vagrant/README.md](../lab/vagrant/README.md).
