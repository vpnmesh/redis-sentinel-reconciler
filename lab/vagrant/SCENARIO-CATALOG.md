# Scenario catalog — master loss / Sentinel desync (Vagrant lab)

Canon outcomes: [`PLAN.md`](PLAN.md) §3.  
IDs are stable; runners filter with `SCENARIOS=A1,A2` or `FAMILY=A`.

---

## Priority

| Band | IDs | When |
|------|-----|------|
| **P0 core** | A1, A2, A3, A9, B-kill-M | first MATRIX slice |
| **P1 expand** | A4, A5, A6, A10, B-restore-orders | after P0 green |
| **P2 backlog** | A7, A8, exotic restore permutations | fill gaps |

---

## Family A — desync / lost-master stories

| ID | Title | Inject | Expected stock (C0) | Expected apply (C2) |
|----|-------|--------|---------------------|---------------------|
| **A1** | Old master returns still writable | Halt M → wait elect → start M without REPLICAOF | `DUAL` or `DESYNC` window | `HEAL_REFUSE` on dual; after demote/stock → `OK_SYNC` or escalate |
| **A2** | Stale Sentinel ad after heal | Halt M → elect → revive M as replica; force 1 Sentinel MONITOR old IP | `STALE_AD` / `DESYNC` | `HEAL_APPLY` → ad→oracle (`OK_SYNC`) |
| **A3** | Long outage, revive only old M | Halt all replicas+majority Sentinels; revive only old M | `STALE_AD` / `ZERO` mid; messy revive | refuse if zero/partition; heal when unique writable |
| **A4** | Minority writable island | Partition 2 nodes (incl writable) from majority Sentinels | split truth | `HEAL_REFUSE` `partition_suspect` |
| **A5** | Equal-epoch disagreeing ads | Force same config-epoch, two ads | flap / `DESYNC` | `equal_epoch_trap` / escalate; no MONITOR thrash |
| **A6** | Sentinel SIGSTOP across failover | STOP sentinel on M’s node; kill Redis M; CONT later | `STALE_AD` | heal local ad when safe |
| **A7** | AOF/disk pressure on master | fill disk / stop writes on M | election or read-only mess | observe; heal ads only |
| **A8** | Delayed HELLO (soft) | tc netem delay between nodes | transient `DESYNC` | dry-run would_heal; apply only if sticky |
| **A9** | Operator wrong MONITOR | `REMOVE+MONITOR` fake/wrong IP on 1..N Sentinels | `BLACKHOLE`/`DESYNC` | `HEAL_APPLY` toward seed oracle |
| **A10** | Quorum loss then bad revive order | Kill ≥quorum Sentinels; revive wrong master first | stuck ads | refuse until min seeds; then heal |

Compose already covers API-shaped A2/A5/A9 (hazards/readiness). Vagrant adds **machine power** and **systemd** restart semantics.

---

## Family B — kill-N + sequential restore

Parameters: `CLUSTER_N`, `k`, `include_master` (default true), `restore_order`.

| ID pattern | Example | Notes |
|------------|---------|-------|
| `B.k{k}.M` | `B.k1.M` | kill k nodes including current master |
| `B.k{k}.R` | `B.k2.R` | kill k **replicas only** (master stays) |
| `B.restore.OLD` | after any B.k* | restore old master first |
| `B.restore.NEW` | | restore a survivor first |
| `B.restore.Q` | | restore until quorum Sentinels live, then data nodes |

**Minimum MATRIX coverage (P0):**

- N=5: `B.k1.M`, `B.k2.M`, `B.k3.M` × restore `OLD` and `NEW` × C0/C2  
- Then extend k=4,5 and N=3/7.

---

## Family C — control rows (always)

| ID | Mode |
|----|------|
| C0 | reconciler units stopped |
| C1 | reconciler dry-run (no `--apply`) |
| C2 | reconciler `--apply` + lease + local-sentinel |

---

## Evidence pack per cell

Each run writes `artifacts/cells/<id>_N<n>_C<c>_k<k>_<ts>/`:

- `topology.txt` — ROLE/SET + all Sentinel ads  
- `journal-reconciler.txt` — if C1/C2  
- `writer.log`  
- `cell.json` — `{outcome, writable, ads[], notes}`

Runner aggregates → `MATRIX-*.csv`.
