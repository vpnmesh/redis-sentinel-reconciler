# Docker Hub: `vpnmesh/redis-sentinel-reconciler`

Create the repository on https://hub.docker.com (namespace `vpnmesh`,
name `redis-sentinel-reconciler`). **Do not** turn on Hub Automated
Builds — `v*` tags are built by GitHub Actions
(`.github/workflows/release.yml`) and pushed here.

## Hub UI — paste this

**Short description** (≤100 characters):

```text
Sidecar that heals stale Redis/Valkey Sentinel master advertisements.
```

**Full description** (markdown):

```markdown
Sidecar next to each Redis/Valkey Sentinel. It finds which Redis
actually accepts writes (`ROLE` + `SET`) and heals
`SENTINEL get-master-addr-by-name` when that pointer is stale.

Does not edit `sentinel.conf`, does not restart Sentinel, does not send
`REPLICAOF`. Dual writable → refuse.

```bash
docker pull vpnmesh/redis-sentinel-reconciler:latest
```

Source, `.deb`, Helm: https://github.com/vpnmesh/redis-sentinel-reconciler
```

Visibility: **Public**.

## GitHub secrets (required for tag push)

Repo **vpnmesh/redis-sentinel-reconciler** → Settings → Secrets:

| Secret | Value |
|--------|--------|
| `DOCKERHUB_USERNAME` | Docker Hub user that can push to `vpnmesh/…` |
| `DOCKERHUB_TOKEN` | Access Token (Hub → Account Settings → Personal access tokens), not the password |

Then:

```bash
git tag v0.1.4
git push origin v0.1.4
```

CI pushes `vpnmesh/redis-sentinel-reconciler:<version>` and `:latest`.
The Helm chart is a separate OCI package on GHCR
(`oci://ghcr.io/vpnmesh/charts`), not on Docker Hub. Chart
`version` / `appVersion` are stamped from the same git tag — do not bump
`Chart.yaml` by hand.
