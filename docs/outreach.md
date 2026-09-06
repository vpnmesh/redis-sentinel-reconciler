# Outreach — where this hole is already being discussed

Paste kit for GitHub / forums. **Do not spam closed issues.** Comment only
when the remaining symptom is: Sentinel still advertises a master that is
not the unique writable Redis (`ROLE` + `SET`).

**Product one-liner:** Sentinel's advertised master must be the Redis that
accepts writes. Sidecar next to each Sentinel heals `get-master-addr-by-name`
via Sentinel API (no `sentinel.conf` edit, no Sentinel restart). Dual
writable: refuse, not `REPLICAOF`.

**Link:** https://github.com/vpnmesh/redis-sentinel-reconciler

**Install:** `.deb` from GitHub Releases; Kubernetes image/chart on GHCR
(see README).

## Suggested comment (English)

```text
If the leftover problem is that SENTINEL get-master-addr-by-name still
names a dead / old master while another Redis accepts writes, restarting
Sentinel or editing sentinel.conf is the usual kludge (control-plane
reboot). We open-sourced a sidecar that sits next to each Sentinel, uses
ROLE+SET as the oracle, and heals the advertisement through Sentinel's
own MONITOR/FAILOVER API — it never sends REPLICAOF and it refuses when
there are two writables.

https://github.com/vpnmesh/redis-sentinel-reconciler
```

## GitHub — Redis / clients (symptom matches)

| Thread | Why it matches |
|--------|----------------|
| https://github.com/redis/redis/issues/8300 | K8s: Sentinel keeps the old master IP after the pod returns |
| https://github.com/redis/redis/issues/10843 | `get-master-addr-by-name` vs `SENTINEL master` disagree after failover |
| https://github.com/redis/redis/issues/11241 | Failover abort / leftover topology (`-failover-abort-no-good-slave`) |
| https://github.com/redis/redis/issues/11701 | Clients treat the master address as a constant; Sentinel is the pointer |
| https://github.com/redis/redis/issues/7753 | `SENTINEL RESET *` as the human hammer |
| https://github.com/redis/redis-py/issues/3560 | Client follows Sentinel; stale ads → writes to the old master |
| https://github.com/redis/redis-py/issues/3874 | Same class: pool does not re-resolve; ads must be true |
| https://github.com/valkey-io/valkey/issues | Same wire protocol; search: sentinel master, get-master-addr |

## GitHub — ask / show (your repo)

| Place | Use |
|-------|-----|
| https://github.com/vpnmesh/redis-sentinel-reconciler/issues | Bug reports |
| https://github.com/vpnmesh/redis-sentinel-reconciler/discussions | Q&A (enable Discussions in repo Settings if not on) |

## Forums / chat

| Place | URL |
|-------|-----|
| Redis Community Forum | https://forum.redis.io/ (e.g. https://forum.redis.io/t/failover-issue-for-redis-sentinel-on-docker-compose/2511) |
| Redis Discord | https://discord.gg/redis · https://redis.io/tutorials/community/discord/ |
| Reddit r/redis | https://www.reddit.com/r/redis/ |
| Reddit r/devops | https://www.reddit.com/r/devops/ |
| Stack Overflow `redis-sentinel` | https://stackoverflow.com/questions/tagged/redis-sentinel |
| redis-db mailing list | https://groups.google.com/g/redis-db |
| Show HN | https://news.ycombinator.com/submit — title like: *Show HN: sidecar that heals stale Redis Sentinel master ads* |
| Valkey Discord / forum | https://valkey.io/community/ |

## Search queries (find *new* threads)

```text
SENTINEL get-master-addr-by-name wrong
Sentinel still pointing to old master
advertised master is down after failover
equal config-epoch sentinel
sentinel.conf MONITOR restart
clients writing to dead redis sentinel
```

## What not to claim in public

- Not a Sentinel replacement and not Redis Cluster.
- Not a dual-master healer (`REPLICAOF` stays Sentinel / human).
- Client write-probe remains best practice; this only makes Sentinel's
  answer match that probe.
