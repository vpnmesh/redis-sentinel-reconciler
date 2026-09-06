# Lab

Docker Compose: 5 Redis + 5 Sentinel (quorum 3), plus `writer` and one
reconciler sidecar per Sentinel with `--apply`. This is how the heal path
is exercised. The shipped package still defaults `APPLY=false`.

Needs Docker Compose v2. Go is only required if you run the binary on
the host; e2e builds the image.

```bash
make up                 # build, start, wait
make e2e                # smoke T01–T09 + matrix A–G (~5–15 min, resets the lab)
make e2e-hazards        # H1–H10 (H7 live requirepass)
make e2e-stress
make e2e-soak           # MONITOR flap, default 60m wall (`SOAK_ROUNDS=4` short)
make e2e-tls            # Redis+Sentinel tls-port + reconciler --apply
make e2e-readiness      # live evidence for the ops claims
make down               # wipe volumes
```

`E2E_RESET=0 make e2e-matrix` reuses a stack that is already up.
Run output lands in `lab/e2e/artifacts/` and is gitignored.

Host ports: Redis `63791–63795`, Sentinel `26379–26383`. Network name
`redis-sentinel-lab`.

```bash
make chaos-kill-redis-master
make chaos-kill-sentinel
make chaos-kill-node1      # redis-1 + sentinel-1
make logs
```

What green means: `fail=0`. Dual/zero writable must refuse. Heal, when
it runs, goes toward the Redis write oracle even if a Sentinel majority
is stale. Stock failover of a dead master should still work without the
reconciler inventing a second writable.

Passwordless plaintext is the lab default. Production TLS/auth:
[docs/configuration.md](../docs/configuration.md).

A systemd-shaped lab (Vagrant + Docker provider) is under
[`vagrant/`](vagrant/). Kind (Bitnami Redis 25.5.3 + our chart) is under
[`kind/`](kind/): `make kind-up` / `make kind-e2e` / `make kind-chaos` / `make kind-stress`.
