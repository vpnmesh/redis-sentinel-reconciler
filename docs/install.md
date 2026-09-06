# Install

One sidecar per Sentinel host. Published builds are **linux/amd64**: a
`.deb` and a `.tar.gz` on each GitHub Release, plus copies with **stable
names** so `/latest/download/` does not need a version in the URL.

The binary is **`/usr/bin/reconciler`**.

Fill two settings before you enable the unit:

| Setting | What |
|---------|------|
| `SENTINEL_ADDR` | Sentinel on **this** host, `host:26379` |
| `REDIS_ADDRS` | Every Redis/Valkey data node that can become master, port **6379** (the whole cluster, not only this host) |

`MASTER_NAME=mymaster` is already set. Leave `APPLY=false` until you have
watched ticks. On TLS, dial the DNS name on the certificate, not
`127.0.0.1`.

## Debian / Ubuntu

```bash
curl -fsSL -o rsr.deb \
  https://github.com/vpnmesh/redis-sentinel-reconciler/releases/latest/download/redis-sentinel-reconciler_linux_amd64.deb
sudo dpkg -i rsr.deb
sudo editor /etc/default/redis-sentinel-reconciler
sudo systemctl enable --now redis-sentinel-reconciler
```

The `/latest/download/redis-sentinel-reconciler_linux_amd64.deb` URL is
the stable name. Older tags only have
`redis-sentinel-reconciler_<version>_amd64.deb` on the [Releases](https://github.com/vpnmesh/redis-sentinel-reconciler/releases)
page — use that until a tag built with this packaging lands.

The package drops:

| Path | What |
|------|------|
| `/usr/bin/reconciler` | binary |
| `/lib/systemd/system/redis-sentinel-reconciler.service` | unit (`--config` + `--local-sentinel`) |
| `/etc/default/redis-sentinel-reconciler` | config (conffile; the process parses it) |

It creates a `redis` system user if needed. It does **not** start the
unit. Empty `SENTINEL_ADDR` / `REDIS_ADDRS` fail the unit (exit 2) with a
short explanation instead of probing the wrong place.

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

## Kubernetes

Runtime image (each `v*` tag):
[`vpnmesh/redis-sentinel-reconciler`](https://hub.docker.com/r/vpnmesh/redis-sentinel-reconciler)
on Docker Hub ([docker-hub.md](docker-hub.md)). Helm chart OCI:
`oci://ghcr.io/vpnmesh/charts/redis-sentinel-reconciler`.

You do **not** run `helm package` yourself to publish. A `v*` tag on
GitHub Actions packages the chart from `deploy/helm/redis-sentinel-reconciler`
(`helm package --version/--app-version` from the tag, so you do not bump
`Chart.yaml`) and `helm push`es it to GHCR. Empty `image.tag` follows
that `appVersion`, so the chart pulls
`vpnmesh/redis-sentinel-reconciler:<same-as-tag>`. One extra step after
the **first** chart appears: GitHub → Packages →
`charts/redis-sentinel-reconciler` → visibility **Public**.
`GITHUB_TOKEN` already logs into `ghcr.io` for that push. Docker Hub
does not host Helm charts.

Fill **both** `sentinelAddr` (this Sentinel) and `redisAddrs` (every data
node, port 6379). Empty lists fail closed. `apply` stays false until you
flip it.

Smoke the published image:

```bash
docker pull vpnmesh/redis-sentinel-reconciler:latest
docker run --rm vpnmesh/redis-sentinel-reconciler:latest -h
```

**DaemonSet** (bare-metal / `hostNetwork`): one pod per node. The chart
already pulls Docker Hub; no `--set image.*` needed.

```bash
helm install rsr oci://ghcr.io/vpnmesh/charts/redis-sentinel-reconciler \
  --set sentinelAddr=db-n1.example.com:26379 \
  --set 'redisAddrs={db-n1.example.com:6379,db-n2.example.com:6379,db-n3.example.com:6379}'
```

From this repo without OCI (git `Chart.yaml` is `0.0.0` → image
`:latest`):

```bash
helm install rsr deploy/helm/redis-sentinel-reconciler \
  --set sentinelAddr=db-n1.example.com:26379 \
  --set 'redisAddrs={db-n1.example.com:6379,db-n2.example.com:6379,db-n3.example.com:6379}'
```

**StatefulSet** next to Bitnami Redis+Sentinel (ordinal → `redis-node-N`):
[lab/kind](../lab/kind/README.md).

**In-pod sidecar** on the Bitnami Redis chart (localhost:26379):
[deploy/examples/bitnami-redis-sidecar.yaml](../deploy/examples/bitnami-redis-sidecar.yaml).
Do not also install our chart in that namespace.

Kind lab still uses a **local** image (`make kind-up`), not Docker Hub.

`apply` stays false until you flip it in values. TLS and ACL:
[configuration.md](configuration.md).

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

Lab check of the Debian install path: `CLUSTER_N=3 make vagrant-pkg`
(after `make vagrant-up`). See [lab/vagrant/README.md](../lab/vagrant/README.md).

## GitHub Release (maintainers)

`.github/workflows/release.yml` builds on a `v*` tag (linux/amd64) and
attaches versioned artifacts, stable `/latest/download/` names, and
`sha256sums.txt`.

```bash
git tag v0.1.4
git push origin v0.1.4
```

The workflow attaches `.deb` / `.tar.gz`, pushes Docker Hub
`vpnmesh/redis-sentinel-reconciler:<version>` and `:latest` (needs secrets
`DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN`, see [docker-hub.md](docker-hub.md)),
and `helm push` to `oci://ghcr.io/vpnmesh/charts` with `Chart.yaml`
`version` / `appVersion` stamped from that tag. After the first chart
package exists, set it **Public** in GitHub → Packages.
