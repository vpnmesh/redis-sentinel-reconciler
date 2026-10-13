# Bitnami Redis chart: in-pod sidecar

Use this when Redis and Sentinel already run as containers in one
StatefulSet (`architecture: replication`, `sentinel.enabled: true`).
The chart creates `<release>-node` with `replica.replicaCount` pods.
Each pod has Redis, Sentinel, and the exporters. One reconciler
container in that pod is one healer for that Sentinel.

`replica.sidecars` is the list the sentinel StatefulSet renders.
`master.sidecars` is a different StatefulSet and is not used while
Sentinel is enabled. Confirm the template in the chart version you
actually install before rolling: the sidecar block has to land in
`templates/sentinel/statefulset.yaml` (or the fork’s equivalent).

Leave our own chart uninstalled in this namespace. A second StatefulSet
would be a second healer per Sentinel.

Copy-paste values:
[deploy/examples/bitnami-redis-sidecar-tls.yaml](../deploy/examples/bitnami-redis-sidecar-tls.yaml).
Plaintext default ports (6379 / 26379):
[deploy/examples/bitnami-redis-sidecar.yaml](../deploy/examples/bitnami-redis-sidecar.yaml).

## Image

Pin a release tag. CI publishes `vpnmesh/redis-sentinel-reconciler:<version>`
where `<version>` is the git tag with the leading `v` removed (`v0.1.5`
→ `0.1.5`). `:latest` is not a pin.

Clusters that already pull through a registry mirror use that registry
and the same repository path:

```text
<mirror>/vpnmesh/redis-sentinel-reconciler:0.1.5
```

Check the tag is visible from the cluster (`docker manifest inspect` or
the registry UI) before the Helm upgrade. The node will not pull Docker
Hub or GHCR if those hosts are closed. Our Helm chart on GHCR is the
wrong artifact for that cluster: the sidecar image is the only thing
the pod needs, and it is already a container in the Redis release.

## Addresses

| Dial | Value |
|------|--------|
| This pod’s Sentinel | `127.0.0.1:<sentinel container port>` |
| Every Redis that can become master | DNS name **on the server certificate**, data port |

Read the ports from the chart values (`containerPorts.redis`,
`containerPorts.sentinel`). A service port remap is not enough: the
process inside the pod has to listen on that port. Default Bitnami is
6379 / 26379. A hardened install often moves them (6380 / 26380).

`REDIS_ADDRS` is the whole set, on every sidecar. Short cluster DNS
(`redis-node-0.redis-headless`) is only valid if that exact name is on
the certificate. Prefer the FQDN that `openssl x509 -ext subjectAltName`
prints.

`sentinel.masterSet` defaults to `mymaster`. If the values file does
not set it, the flag stays `--master-name=mymaster`.

## TLS

Mount the pod volume the chart already creates for Redis TLS. The
chart in `ansible-redis-helm` (`files/redis` 17.10.1) names it
`redis-certificates`, mode `0400` (`defaultMode: 256`), mounted at
`/opt/bitnami/redis/certs`. The pod `fsGroup` and the Redis container
are `1001`. Run the sidecar as `1001` as well, so it can read `ca.crt`.
`65534` is the image default and is wrong for this volume.

```text
--tls
--tls-ca-file=/opt/bitnami/redis/certs/ca.crt
```

`--tls-server-name` applies only when the dial host is an IP. Hostname
dials use the name in `--redis-addrs` and ignore that flag.

| Certificate SAN | Sentinel dial |
|-----------------|---------------|
| Contains `IP:127.0.0.1` | `127.0.0.1:<port>` verifies with no server name |
| DNS names only | `127.0.0.1:<port>` plus `--tls-server-name=<one DNS SAN>` |

One static server name is enough when every pod presents the same
certificate and that name is on it. The scratch image has no shell, so
do not try to build the name from `POD_NAME`.

Leave `--tls-skip-verify` off. Client certs stay off when
`tls.authClients` is false.

Password: the Bitnami secret for this release, key `redis-password`,
into `RSR_REDIS_PASSWORD` and `RSR_SENTINEL_PASSWORD`. Release `redis`
is secret `redis`. A release whose name already contains `redis` keeps
that name (`testops-redis-external` → secret `testops-redis-external`).
Confirm with `kubectl get secret` in the namespace. Empty username is
`AUTH <password>`.

Observe mode still runs `SET rsr:probe` on the writable Redis. It does
not change Sentinel until `--apply` is present.

## Metrics

`--metrics-addr=:9123` (all interfaces). `127.0.0.1:9123` is reachable
only inside the pod, so a scraper never sees it.

The Redis pod already advertises other ports:

| Annotation | Typical port | Container |
|------------|--------------|-----------|
| `prometheus.io/port` | 9121 | redis-exporter |
| `prometheus-second.io/port` | 9478 | sentinel-exporter |

Pod annotations are one map. A second `prometheus.io/port` replaces the
exporter scrape. Put the reconciler on a free prefix, on
`replica.podAnnotations`, and declare `containerPort: 9123` on the
sidecar. The scrape job must keep the target only when the annotation
port equals that container port (same `keep_if_equal` as the existing
pod jobs). One target per pod.

A ClusterIP Service in front of these pods is a single target. The
Service load-balances, so gauges from the other Sentinels never appear.

Scrape job (clone of the existing second pod job; annotation prefix
`prometheus-third.io`):

```yaml
- job_name: kubernetes-pods-third
  honor_labels: true
  kubernetes_sd_configs:
    - role: pod
  metrics_path: /metrics
  relabel_configs:
    - action: drop
      source_labels: [__meta_kubernetes_pod_container_init]
      regex: "true"
    - action: keep_if_equal
      source_labels:
        - __meta_kubernetes_pod_annotation_prometheus_third_io_port
        - __meta_kubernetes_pod_container_port_number
    - source_labels: [__meta_kubernetes_pod_annotation_prometheus_third_io_scrape]
      action: keep
      regex: true
    - source_labels: [__meta_kubernetes_pod_annotation_prometheus_third_io_path]
      action: replace
      target_label: __metrics_path__
      regex: (.+)
    - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_third_io_port]
      action: replace
      regex: ([^:]+)(?::\d+)?;(\d+)
      replacement: $1:$2
      target_label: __address__
    - source_labels: [__meta_kubernetes_pod_name]
      target_label: pod
    - source_labels: [__meta_kubernetes_pod_container_name]
      target_label: container
    - source_labels: [__meta_kubernetes_namespace]
      target_label: namespace
    - source_labels: [__meta_kubernetes_pod_node_name]
      target_label: node
    - source_labels: [__meta_kubernetes_pod_node_name]
      target_label: instance
```

Alert rules, after the series exist:
[deploy/observability/prometheus-alerts.yaml](../deploy/observability/prometheus-alerts.yaml).
A 30s scrape interval still fits those windows. Counters are `*_total`;
use `rate` / `increase`.

## Rollout

`--apply` stays off on the first upgrade. The pod template change rolls
every Redis pod. One environment, then the next. Watch Sentinel quorum
through the roll. Do not change the Redis image tag in the same diff.

The start log line carries `"apply":false`. Later ticks log
`would_heal` and do not log `heal succeeded`. Kill switch and dwell:
[operations.md](operations.md).
