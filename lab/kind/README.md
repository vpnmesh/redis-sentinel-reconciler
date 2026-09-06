# Kind: Bitnami Redis + our chart

Local Kubernetes install smoke. **Does not publish an image.**

| Piece | What |
|-------|------|
| Kind cluster `rsr` | one control-plane node |
| Bitnami Redis **25.5.3** | 3 pods, Sentinel in each pod (`replica.replicaCount=3`) |
| Our chart | 3-pod StatefulSet; `rsr-0` talks to `redis-node-0.redis-headless:26379` |
| Image | `redis-sentinel-reconciler:local` via `docker build` + `kind load` |

Redis images are `bitnamilegacy/redis:8.2.1` / `bitnamilegacy/redis-sentinel:8.2.1` so Kind does not need a Bitnami Secure Images login. Chart 25 *can* inject a sidecar with `replica.sidecars` (localhost:26379). Kind still installs **our chart** so that path is tested. Optional in-pod sidecar: [`values-redis-sidecar.yaml`](values-redis-sidecar.yaml). Do not also install the STS chart if you use it.

```bash
# from redis-sentinel-reconciler/
make kind-up      # cluster + image + helm
make kind-e2e     # PING, ads agree, wrong MONITOR, --apply heals
make kind-chaos   # replica kill, rsr kill mid-heal, replica advertised as master, dual refuse
make kind-stress  # MONITOR flap ×N, heal-lease herd, dual refuse ticks
make kind-test    # e2e + chaos + stress (one cluster bring-up)
make kind-down
```

Needs `kind`, `helm`, `kubectl`, `docker` on PATH. Redis chart is pulled from
`oci://registry-1.docker.io/bitnamicharts/redis:25.5.3` (same version as
https://charts.bitnami.com/bitnami).

`kind-e2e` MONITOR's every Sentinel onto `10.255.255.254` (unreachable) with
the reconciler STS scaled to 0, then scales it back with `--apply` and waits
for `heal succeeded` with ads back on the writable Redis. The Kind values
file sets `apply: true`; chaos/stress leave it on. That is the lab evidence
for “`--apply` on every sidecar”, not a production soak. The shipped Helm
chart still defaults `apply: false`.

Chaos/stress hit the reconciler, not generic Redis HA:

| Target | Cases |
|--------|--------|
| `kind-chaos` | C1 delete one rsr pod (oracle holds); C3 ads name a live replica; C2 delete rsr pods mid-heal; C4 `REPLICAOF NO ONE` is `dual_master` refuse, no `REPLICAOF` from us |
| `kind-stress` | S2 three apply pods contend `--heal-lease`; S1 fake MONITOR × `STRESS_ROUNDS` (default 6); S3 dual refuse for several ticks |

Password is lab-only: `lab-rsr-kind` in [`values-redis.yaml`](values-redis.yaml).
