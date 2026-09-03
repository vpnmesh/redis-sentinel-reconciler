# Plan: Vagrant (Docker) bare-metal-like lab + master-loss matrix

**Status:** binding plan · Hands start 2026-08-09 · **P1 smoke GREEN (N=3)**  
**Smoke ART:** [`artifacts/RESULT-VAGRANT-SMOKE-N3-20260809.md`](artifacts/RESULT-VAGRANT-SMOKE-N3-20260809.md)  
**Product:** `redis-sentinel-reconciler`  
**Canon:** [`docs/docs/architecture/redis-sentinel-reconciler.md`](../../../docs/docs/architecture/redis-sentinel-reconciler.md)

---

## 0. Goal (one sentence)

Reproduce **Sentinel master advertisement desync / master loss** on **systemd-shaped nodes** (Vagrant + Docker provider ≈ bare-metal), then measure outcomes **with vs without reconciler** across **cluster sizes 3 / 5 / 7** and **kill-N → sequential restore**, and publish a **diagram + table** of expected results.

---

## 1. Two lab tiers (do not mix)

| Tier | Path | Role | Gate |
|------|------|------|------|
| **L1-fast** | `lab/docker-compose.yml` + `make e2e-*` | Seconds–minutes; API chaos; readiness R1–R22 | Already green |
| **L1.5-bare** | `lab/vagrant/` (this plan) | Minutes–hours; **systemd** Redis/Sentinel/reconciler; power-off / disk / network like prod | New |

**Rule:** Compose stays the default CI/dev loop. Vagrant is the **industrial** matrix; it must not slow L1-fast.

---

## 2. Topology model (bare-metal analogy)

Each Vagrant machine `node-N` runs **one colocated stack** (prod sidecar shape):

```text
┌─ node-i (systemd) ─────────────────────────┐
│  redis-server.service                      │
│  redis-sentinel.service                    │
│  redis-sentinel-reconciler.service         │
│    --local-sentinel --sentinel-addr=127.0.0.1:26379
│    --redis-addrs=<all node IPs>:6379       │
└────────────────────────────────────────────┘
```

| Parameter | Values | Notes |
|-----------|--------|-------|
| `CLUSTER_N` | **3 / 5 / 7** | Redis + Sentinel + reconciler per node |
| Quorum | `floor(N/2)+1` → 2 / 3 / 4 | Stock Sentinel |
| Provider | **Docker** (`jrei/systemd-ubuntu:22.04`) | privileged + cgroup host |
| Default bring-up | **N=5** | Matches current compose mental model |

Kill/restore unit = **whole machine** (`vagrant halt` / `docker stop` / `systemctl stop` of the three units) — not only Redis process (Compose already covers process-level).

---

## 3. What we measure (oracles)

Every cell records:

| Signal | Source |
|--------|--------|
| Writable Redis count | `ROLE` + `SET` probe on every seed |
| Sentinel ads | `SENTINEL get-master-addr-by-name` on **each** live Sentinel |
| Epoch / flags | `SENTINEL master` → `config-epoch`, `flags` |
| Client write | lab `writer` or `redis-cli SET` via Sentinel discovery |
| Reconciler | journald: `would_heal` / `heal succeeded` / `dual_master` / `conf_fallback_needed` / `apply_refused` |

**Outcome vocabulary (binding):**

| Code | Meaning |
|------|---------|
| `OK_SYNC` | unique writable ∧ all live Sentinels advertise that IP ∧ client SET ok |
| `OK_STOCK` | stock Sentinel healed without reconciler apply |
| `DESYNC` | ads disagree or ad ≠ writable oracle |
| `STALE_AD` | all ads agree on **down / old** master while writable is elsewhere (classic “lost master”) |
| `DUAL` | ≥2 writables |
| `ZERO` | 0 writables |
| `BLACKHOLE` | ads point to unreachable; clients fail |
| `HEAL_APPLY` | reconciler `--apply` restored `OK_SYNC` |
| `HEAL_REFUSE` | reconciler correctly refused (dual/zero/partition/…) |
| `WORSE` | reconciler apply made topology worse (must be 0 in green matrix) |
| `BLOCKED` | lab infra could not run cell |

---

## 4. Scenario families (catalog detail → `SCENARIO-CATALOG.md`)

### A — Classic “master lost / Sentinel wrong”

| ID | Story (prod-shaped) |
|----|---------------------|
| A1 | Kill current master VM → stock elects M2 → restart old M1 still as master briefly → **stale/dual window** |
| A2 | Kill master → elect M2 → restart M1 as replica, but **one Sentinel still ads M1** (lie / lag) |
| A3 | Kill master long enough → all Sentinels `s_down` → revive **old** master only → ads stuck / wrong epoch |
| A4 | Network partition: majority Sentinels see island; minority has writable (false-oracle) |
| A5 | Equal `config-epoch` + disagreeing ads (de-n1 class) |
| A6 | Freeze Sentinel process (SIGSTOP) while Redis fails over → thaw → stale ad |
| A7 | Disk full / appendonly fail on master → demote path messy |
| A8 | Clock skew / long GC pause (soft): delayed HELLO → temporary desync |
| A9 | Operator `SENTINEL REMOVE+MONITOR` to wrong IP (manual desync) |
| A10 | Quorum loss (kill enough Sentinels) then revive wrong order |

### B — Kill-N then sequential restore (combinatorics)

For `CLUSTER_N ∈ {3,5,7}` and `k ∈ {1..N}`:

1. Identify current writable master node `M`.
2. **Kill** `k` nodes (include `M` in first wave when `k≥1` — primary path; also subcases kill-replicas-only).
3. Observe mid-state (stock ± reconciler).
4. **Restore node-by-node** in orders:
   - `R_OLD_FIRST` — old master first
   - `R_NEW_FIRST` — survivor / new master first  
   - `R_SENTINEL_HEAVY` — nodes that had majority Sentinels first
5. Snapshot after each restore step.

### C — Reconciler modes (rows of the result table)

| Row | Mode |
|-----|------|
| C0 | Reconciler **absent** / units stopped |
| C1 | Reconciler **dry-run** (`APPLY_FLAG=` empty) — observe only |
| C2 | Reconciler **`--apply`** + `--local-sentinel` + lease (prod canary shape) |

### D — Cluster size columns

| Col | N | Quorum |
|-----|---|--------|
| S3 | 3 | 2 |
| S5 | 5 | 3 |
| S7 | 7 | 4 |

---

## 5. Result artifact (diagram + table)

**Files (generated + checked-in skeleton):**

| Artifact | Role |
|----------|------|
| `lab/vagrant/artifacts/MATRIX-*.csv` | machine-readable cells |
| `lab/vagrant/artifacts/MATRIX-*.md` | human table |
| `lab/vagrant/artifacts/diagram-outcomes.mmd` | mermaid: scenario → outcome |
| `docs/VAGRANT-OUTCOME-MATRIX.md` | tip-pinned summary (when first green slice exists) |

**Table shape (minimum):**

```text
scenario × restore_order × kill_k
        | N=3 C0 | N=3 C2 | N=5 C0 | N=5 C2 | N=7 C0 | N=7 C2 |
--------+--------+--------+--------+--------+--------+--------+
A1 k=1  | ...    | ...    | ...    | ...    | ...    | ...    |
B k=2 R_OLD_FIRST | ...
```

Optional third row band for **C1 dry-run** (expect `DESYNC`/`STALE_AD` + `would_heal`, never `HEAL_APPLY`).

---

## 6. Delivery phases (Hands)

| Phase | Deliverable | Exit |
|-------|-------------|------|
| **P0** | This plan + scenario catalog + matrix schema | docs only |
| **P1** | Vagrantfile N=5, provision Redis+Sentinel+systemd reconciler, `vagrant up` smoke | 5 nodes PING + quorum |
| **P2** | Chaos CLI: `halt`/`up` node, snap oracles, writer probe | one A1 cell recorded |
| **P3** | Runner: A1–A3 × C0/C2 × N=5 | MATRIX slice green |
| **P4** | Kill-N×restore orders × N=5 | expand MATRIX |
| **P5** | Parameterize N=3 and N=7 | full width |
| **P6** | Tip `docs/VAGRANT-OUTCOME-MATRIX.md` | publish |

**Out of scope for P1–P3:** real VirtualBox/libvirt, multi-tenant, conf-escape auto, Owner L2 staging.

**Lab e2e Runner:** long Vagrant matrix → Task `composer-2.5` (Owner 2026-08-23: **never** `-fast`). Hands builds harness + short smoke.

---

## 7. Make / UX

```bash
# fast (unchanged)
make e2e-readiness

# bare-metal-like
make vagrant-up          # CLUSTER_N=5 default
make vagrant-smoke
make vagrant-matrix      # A-slice then expand
CLUSTER_N=3 make vagrant-up
```

Kill-switch: stop reconciler units or empty `APPLY_FLAG` on all nodes (same as prod).

---

## 8. Risks / mitigations

| Risk | Mitigation |
|------|------------|
| Docker+systemd flaky cgroup | privileged + `--cgroupns=host`; document host kernel |
| RAM for N=7 | default N=5; N=7 opt-in |
| False-green Compose-only | MATRIX cells require VM journal + Redis ROLE evidence |
| Combinatorial explosion | Prioritize A1–A5 + kill-k with M included; mark rest backlog in catalog |
| Reconciler `WORSE` | any `WORSE` → FAIL cell + hazard ticket |

---

## 9. Engine dual (soft)

| `ENGINE` | Install path | Notes |
|----------|--------------|-------|
| `redis` (default) | apt `redis-server` inside node | CI / Compose parity |
| `valkey` | `make vagrant-engine-bins` → `lab/vagrant/bins/valkey/` mounted RO | Same Sentinel API; matrix cells should tag `engine=` |

Repo name unchanged. Product claim: **Redis-compatible Sentinel** (Redis + Valkey).

## 10. Status / next

| Done | Next |
|------|------|
| P0–P2 slice: Redis N=5 smoke + **matrix A9/A1 PASS** (Runner) | A02/A03 scripts; Valkey N=5 opt |
| Valkey N=3 smoke + A9 PASS; Ubuntu 24.04 | |
| Bootstrap: `resolve-hostnames` **Valkey-only** (Redis 6.0 crash hazard closed) | N=7 opt-in; publish MATRIX tip |

Runner ART: [`artifacts/RESULT-VAGRANT-MATRIX-A1A3-N5-20260809.md`](artifacts/RESULT-VAGRANT-MATRIX-A1A3-N5-20260809.md)
