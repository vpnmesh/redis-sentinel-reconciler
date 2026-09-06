# Docker Hub: `vpnmesh/redis-sentinel-reconciler`

Create the repository on https://hub.docker.com (namespace `vpnmesh`,
name `redis-sentinel-reconciler`). **Do not** turn on Hub Automated
Builds. `v*` tags are built by GitHub Actions
(`.github/workflows/release.yml`) and pushed here.

The Helm chart is **not** on Hub. It lives on GHCR:
`oci://ghcr.io/vpnmesh/charts/redis-sentinel-reconciler`
([package](https://github.com/vpnmesh/redis-sentinel-reconciler/pkgs/container/charts%2Fredis-sentinel-reconciler)).
Set that package **Public**.

## Hub UI: paste this

**Short description** (100 characters or less):

```text
Sidecar that heals stale Redis/Valkey Sentinel master advertisements.
```

**Full description** (markdown):

```markdown
Sidecar next to each Redis/Valkey Sentinel. It finds which Redis
actually accepts writes (`ROLE` + `SET`) and heals
`SENTINEL get-master-addr-by-name` when that pointer is stale.

Does not edit `sentinel.conf`, does not restart Sentinel, does not send
`REPLICAOF`. Dual writable: refuse.

```bash
docker pull vpnmesh/redis-sentinel-reconciler:latest
helm install rsr oci://ghcr.io/vpnmesh/charts/redis-sentinel-reconciler \
  --namespace rsr \
  --set replicaCount=3 \
  --set sentinelFromOrdinal.prefix=redis-node- \
  --set 'redisAddrs={redis-node-0.redis-headless:6379,redis-node-1.redis-headless:6379,redis-node-2.redis-headless:6379}' \
  --set auth.existingSecret=redis
```

Source and `.deb`: https://github.com/vpnmesh/redis-sentinel-reconciler
```

Visibility: **Public**.

## GitHub secrets

Repo **vpnmesh/redis-sentinel-reconciler**, Settings, Secrets:

| Secret | Value |
|--------|--------|
| `DOCKERHUB_USERNAME` | Docker Hub user that can push to `vpnmesh/...` |
| `DOCKERHUB_TOKEN` | Access Token (Hub Account Settings, Personal access tokens), not the password |

```bash
git tag v0.1.4
git push origin v0.1.4
```

CI pushes `vpnmesh/redis-sentinel-reconciler:<version>` and `:latest`,
and `helm push` to `oci://ghcr.io/vpnmesh/charts`.
`Chart.yaml` `version` / `appVersion` are stamped from the git tag.
