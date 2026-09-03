# Install

Published builds are **linux/amd64** only: a `.tar.gz` and a `.deb` on
the GitHub Release for each `v*` tag. `sha256sums.txt` sits next to them.

The binary is **`/usr/bin/reconciler`**. That is the path in the unit,
the deb, and the tarball install snippet.

## Debian package

```bash
sudo dpkg -i redis-sentinel-reconciler_<version>_amd64.deb
```

The package drops:

| Path | What |
|------|------|
| `/usr/bin/reconciler` | binary |
| `/lib/systemd/system/redis-sentinel-reconciler.service` | unit (`--config` + `--local-sentinel`) |
| `/etc/default/redis-sentinel-reconciler` | config (conffile, parsed by the process) |

It creates a `redis` system user if one does not already exist. It does
**not** enable or start the unit — fill in Redis addresses and passwords
first. A missing config file fails the unit (exit 2). That is better than
starting with no `SENTINEL_ADDR`.

```bash
sudo editor /etc/default/redis-sentinel-reconciler
sudo systemctl enable --now redis-sentinel-reconciler
```

Removing the package stops the unit. The env file stays behind as a
conffile until `apt purge`.

`reconciler -h` must list `-tls`, `-redis-username`, `-sentinel-username`.
If a binary does not, it is stale relative to this tree — do not ship it.

## Tarball

```bash
tar -xzf redis-sentinel-reconciler_<version>_linux_amd64.tar.gz
cd redis-sentinel-reconciler_<version>_linux_amd64
sudo install -m 0755 reconciler /usr/bin/reconciler
sudo install -m 0644 systemd/redis-sentinel-reconciler.service \
  /lib/systemd/system/redis-sentinel-reconciler.service
sudo install -m 0640 -o root -g redis systemd/redis-sentinel-reconciler.default \
  /etc/default/redis-sentinel-reconciler   # or root:root if you have no redis group yet
sudo systemctl daemon-reload
```

## Build locally

```bash
make dist          # tarball + deb into dist/
# or
./scripts/package-linux-amd64.sh
```

`VERSION` defaults to `git describe` (with a `v` prefix stripped). Override
it when you need a specific Debian upstream version:

```bash
VERSION=0.1.1 ./scripts/package-linux-amd64.sh
```

Needs Go 1.23+, and `dpkg-deb` for the `.deb` (any Debian/Ubuntu builder).

The binary reports its stamp with `--version`.

## GitHub Release

`.github/workflows/release.yml` builds the tarball and `.deb` on a `v*`
tag (linux/amd64) and attaches them to the release, plus `sha256sums.txt`.
`workflow_dispatch` builds the same artifacts without publishing.

```bash
git tag v0.1.1
git push origin v0.1.1
```

CI on pull requests is `.github/workflows/ci.yml` (`go test` / `go vet` /
`reconciler -h` flag lockstep).

These workflow files live in **this** repository root. They run when this
tree is the GitHub repo (github.com/vpnmesh/redis-sentinel-reconciler).
Inside the VpnMesh monorepo they are inert unless you copy them to that
repo’s `.github/workflows`.
