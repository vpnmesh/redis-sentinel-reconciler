# Install: Docker image + Helm

Runtime image:
[`vpnmesh/redis-sentinel-reconciler`](https://hub.docker.com/r/vpnmesh/redis-sentinel-reconciler)
(`:latest` and each `v*` tag). Maintainer Hub notes: [docker-hub.md](docker-hub.md).

Helm chart is an OCI package on GHCR:
`oci://ghcr.io/vpnmesh/charts/redis-sentinel-reconciler`.
GitHub's Packages UI labels it "Container"; it is the chart, not the
sidecar image. The package must be **Public** or anonymous `helm
install` gets 401.

**One reconciler pod per Sentinel.** Clients ask any Sentinel;
`get-master-addr-by-name` is per process. A single reconciler cannot
stand in for the other two.

Every process needs both addresses. Empty lists fail closed. Leave
`apply` false until ticks look quiet.

| Setting | What |
|---------|------|
| `SENTINEL_ADDR` | This pod's Sentinel, `host:26379` (STS derives it from `POD_NAME`) |
| `REDIS_ADDRS` | Every Redis/Valkey data node that can become master, port 6379 |

Flags and TLS: [configuration.md](configuration.md).

## Smoke the image

```bash
docker pull vpnmesh/redis-sentinel-reconciler:latest
docker run --rm vpnmesh/redis-sentinel-reconciler:latest -h
```

`docker run` without the two addresses exits 2. That is expected.

## Helm (StatefulSet, same namespace as Redis)

Default `workload` is **StatefulSet**, `replicaCount: 3`, ordinal prefix
`redis-node-` (Bitnami Redis chart names, no `fullnameOverride`). Install
in the **same namespace** as Redis+Sentinel.

```
namespace rsr
  redis-sentinel-reconciler-0  talks to  redis-node-0  (Redis + Sentinel :26379)
  redis-sentinel-reconciler-1  talks to  redis-node-1  (Redis + Sentinel :26379)
  redis-sentinel-reconciler-2  talks to  redis-node-2  (Redis + Sentinel :26379)
```

Copy-paste ([deploy/examples/bitnami-sts.yaml](../deploy/examples/bitnami-sts.yaml)):

```bash
helm install rsr oci://ghcr.io/vpnmesh/charts/redis-sentinel-reconciler \
  --namespace rsr \
  --set replicaCount=3 \
  --set sentinelFromOrdinal.enabled=true \
  --set sentinelFromOrdinal.prefix=redis-node- \
  --set sentinelFromOrdinal.suffix=.redis-headless:26379 \
  --set 'redisAddrs={redis-node-0.redis-headless:6379,redis-node-1.redis-headless:6379,redis-node-2.redis-headless:6379}' \
  --set auth.existingSecret=redis
```

`--set auth.existingSecret=redis` is the Bitnami secret for a release
named `redis` (key `redis-password`). Without it the logs are
`NOAUTH Authentication required` on both `:26379` and `:6379`.

Use headless DNS (`redis-node-0.redis-headless`), not `redis-node-0:6379`.
If you renamed pods (`fullnameOverride`), change `prefix` to match.

Omit `--version` so Helm takes the latest chart. Pin a chart version only
in your own lockfile after you have watched ticks. Empty `image.tag`
follows the chart `appVersion`.

**DaemonSet** only if Sentinel runs on the host (`hostNetwork`):

```bash
helm install rsr oci://ghcr.io/vpnmesh/charts/redis-sentinel-reconciler \
  --set workload=DaemonSet \
  --set sentinelFromOrdinal.enabled=false \
  --set sentinelAddr=db-n1.example.com:26379 \
  --set 'redisAddrs={db-n1.example.com:6379,db-n2.example.com:6379,db-n3.example.com:6379}'
```

Do not run DaemonSet and StatefulSet in the same namespace.

If you still see `401 unauthorized` from GHCR: GitHub Packages, package
`charts/redis-sentinel-reconciler`, set visibility to **Public**.

In-pod sidecar (same netns as Sentinel, `127.0.0.1:26379`):
[deploy/examples/bitnami-redis-sidecar.yaml](../deploy/examples/bitnami-redis-sidecar.yaml).
Do not also install our chart in that namespace.

Kind lab still builds a local image (`make kind-up`).

## Maintainer: publish

Push a `v*` tag. CI stamps the chart version from that tag, pushes the
Docker Hub image, and `helm push` to GHCR. After the first chart package
exists, set it Public once. Do not bump `Chart.yaml` by hand.
