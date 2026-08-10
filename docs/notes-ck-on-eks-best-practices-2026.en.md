# ClickHouse on EKS — Production Best-Practices Notes (2026-07)

[中文](./notes-ck-on-eks-best-practices-2026.md) · **English**

> Origin: starting from the awslabs data-on-eks clickhouse-on-eks reference stack (Altinity Operator + Keeper + Karpenter + ArgoCD, with a 3×3 example), this document works through each layer and arrives at a deployment position of its own.
> Reference page: https://awslabs.github.io/data-on-eks/docs/datastacks/databases/clickhouse-on-eks

---

## 0. Applicability Boundaries of These Best Practices (Clarify the Scope First)

**These recommendations target a specific role: the upstream data lakehouse holds the sole authoritative Source of Truth, while CK is its downstream, derived, eventually consistent, rebuildable OLAP / BI serving acceleration layer.**

Within this role, all the tradeoffs below are internally consistent and close to optimal. But this is not "the one correct solution for CK on EKS" — the tradeoffs change in the following situations, so do not apply it rigidly:

- CK must be the **primary store / sole SoT** (with no upstream lakehouse fallback) → durability requirements rise sharply, the local-NVMe approach no longer works, and the design must return to EBS + backups as the foundation.
- **Extremely high-throughput real-time ingestion** (such as large-scale direct Kafka ingestion, with writes outweighing reads) → write amplification becomes the primary constraint, and both replica and sharding strategies must be reevaluated.
- **Very large scale, where a single query must fan out across many machines** → true sharding is mandatory; 1-shard scale-up cannot handle it.

**Conclusion: it is more accurate to call this "best practices for CK as a lakehouse-derived serving layer on EKS." It is strong within that scope; do not treat it as a universally applicable template.**

---

## 1. Topology Fundamentals (Fix the Concepts First; Everything Later Depends on Them)

### shard = horizontal partitioning by rows, not by columns
- Each shard stores a **subset of the table's rows**, with the same schema; only their union forms the complete table.
- CK is columnar, but "columnar storage" means that data is organized by column **on disk within a single node**; "sharding" means partitioning by row **across nodes**. These are two orthogonal dimensions. **There is no column-level sharding.**
- The hash of the sharding key determines which shard receives a row (the reference uses `cityHash64(UserID)`). Distribution is approximately balanced, **not guaranteed to be exactly even** — skewed keys can make one shard oversized.
- The minimum shard count is **1** (0 does not exist). Any positive integer is valid (2/4/7…).

### replica = a complete copy of the same shard, multi-master, with no primary/secondary
- **Critical correction**: CK's ReplicatedMergeTree is **multi-master and peer-to-peer (masterless)**, not primary-replica like MySQL/PG/Redis.
  - There is no "primary replica" role, **no primary/secondary election, and no failover promotion**.
  - Every replica can read and write; if one goes down, the others continue normally, and after restart it reconciles with Keeper and catches up by itself.
  - (Historical baggage: old versions had a "leader" that only scheduled merges and had nothing to do with reads or writes; after 20.5 there are multiple leaders, so that bottleneck has largely disappeared. Do not impose the "primary/secondary" model on CK.)
- Replica counts have **no odd/even requirement** (2/4 are both valid). ⚠️ Do not confuse this with **Keeper** — Keeper uses Raft and needs an odd number (3/5) to form a quorum; **data replicas do not use quorum** (replication is asynchronous by default).

### What each of the two dimensions solves (the core mental model)
```
Want one "query" to run faster / store more data  →  add SHARDS (horizontal partitioning, by row)
Want to handle more "concurrent queries" / keep serving through failures  →  add REPLICAS (redundancy, multi-master peers)
```

### Analogy with Kafka/MSK (shift the comparison by one position)
```
Kafka partition  ≈  CK SHARD    ← parallelism/partitioning unit
Kafka replica    ≈  CK REPLICA  ← redundancy unit
```
- Parallelism comes from shards, not replicas (as with Kafka: parallelism comes from the number of partitions).
- **Difference**: Kafka followers do not serve clients by default (follower reads arrived only with KIP-392); **all CK replicas are readable**.

---

## 2. Recommended Starting Point: 1 Shard × 3 Replicas + Large Nodes (Scale Up First)

**The right mental model for CK is "make a single node larger first; sharding is the last resort,"** because:
- A single CK node can handle far more data than intuition suggests (terabytes after compression are no problem).
- **Re-sharding is extremely painful**: CK has no automatic rebalance; after adding a shard, old data does not move automatically and must be reloaded manually with `INSERT SELECT` or `clickhouse-copier`.

Therefore, the recommended default topology is: **no sharding (`shardsCount: 1`) + 3 replicas + each replica exclusively occupies one large Graviton, spread across 3 AZs.**

```
        replica r1        replica r2        replica r3
       ┌──────────┐      ┌──────────┐      ┌──────────┐
       │ large pod│ ≈≈≈  │ large pod│ ≈≈≈  │ large pod│   full data × 3 complete copies
       │  AZ-a    │      │  AZ-b    │      │  AZ-c    │
       └──────────┘      └──────────┘      └──────────┘
   1 shard = every node has the full table, with no horizontal partitioning; each pod exclusively occupies one EC2 instance
```

**Why this is the optimal starting point:**
- ✅ Zero re-sharding pain (you never face CK's most painful operational task).
- ✅ No cross-shard fan-out, the shortest query path, and no coordinator overhead for aggregating multiple shards.
- ✅ HA + read scaling are both in place: if 1 machine fails, 2 copies remain; read QPS is approximately 3×.
- ✅ Scaling is extremely simple: insufficient reads → add replicas (add an STS without changing data layout); insufficient resources → switch to a larger instance type. Neither touches data partitioning.

**Two points you must remember:**
1. **Keeper cannot be omitted**. As long as a `Replicated` engine is used, replication coordination goes through Keeper, **regardless of the number of shards**. A 1×3 topology still needs a 3-node Keeper ensemble. Common misconception: "No sharding means no Keeper" — wrong.
2. **Do not use Distributed tables**. With 1 shard, each replica has all the data, so there is no need for cross-node fan-out. Distributed only adds a needless hop. Put an LB in front of the clients to round-robin across the 3 pods, **query the local ReplicatedMergeTree tables directly**, and reads will naturally spread across the 3 replicas.

**When do you hit a wall → and only then introduce shards (three thresholds; hitting any one qualifies):**
1. The complete dataset no longer fits on one node (compressed data exceeds a single machine's disk / the maximum EBS/NVMe attachable to an instance type).
2. **A single large aggregation is too slow** — with 1 shard, one query can use only one machine's compute; replicas do not accelerate a single query. Heavy aggregations that scan most of a table will be bottlenecked by one machine's CPU. (The most common hidden limit.)
3. Ingestion throughput exceeds one node's limit (less common).

**The decisive tool for delaying that wall: `parallel_replicas`**. Once enabled, a query can call multiple replicas of the same shard to scan the same data in parallel, effectively letting "replicas" temporarily double as "shards," so a single query also gets N× parallelism. This is especially valuable in a 1-shard topology — when "a single query is slow" but you do not yet want real sharding, enabling this first can often postpone sharding for a long time. (Maturity: it has become more stable in recent versions; check the changelog when pinning a version.)

---

## 3. Quantitative Sizing

### Number of shards vs data volume
Do not simply divide the total volume. Take the **maximum of three limits**:
```
shards = max( storage-driven, single-query-latency-driven, ingestion-driven )
```
1. **Storage-driven**: `shards = ceil(total compressed data volume / target capacity per shard)`. The target capacity of a single shard depends on the query shape:
   - Good index selectivity (point lookups/filters on leading columns, scanning only a few granules) → a single node can reach **tens of TB**; capacity is constrained by disk, not queries.
   - Scan/aggregation-heavy (large-range GROUP BY) → consider sharding at **1–4 TB**, because the amount scanned by one query ∝ the amount of data on one node.
   - ⚠️ Always calculate using the **compressed** size (CK typically achieves 5–10× compression); do not let raw volume scare you into excessive sharding.
2. **Single-query-latency-driven**: fan-out width = number of shards; scanning N rows across K shards → each scans N/K, for approximately linear speedup. Work backward from "this large aggregation must finish within X seconds" to determine the required parallelism.
3. **Ingestion-driven**: a single node can insert hundreds of MB/s to GB/s, so this is usually not the binding constraint.

- Total nodes = `shards × replicas`; each machine stores `total volume/shards` (not /number of nodes, because replicas are complete copies).
- Recommendation: first build a large single node → add shards only after hitting "does not fit/cannot scan fast enough" → choose the shard count from the larger storage/latency limit, and **leave enough room from the start** (re-sharding is far more expensive than provisioning headroom).

### Number of replicas vs QPS
- **Read QPS grows approximately linearly with the number of replicas**, and the read path does not touch Keeper (Keeper is used only on write/DDL paths), so scaling is clean.
- Two prerequisites for obtaining linear scaling:
  1. **Concurrency must be distributed across replicas**: use `load_balancing` (the default in newer versions is `random`) + **spread client connections across all nodes** (put an LB in front for round-robin). Otherwise, all connections pressure the same coordinator, hit its aggregation bottleneck first, and additional replicas are useless.
  2. **The bottleneck must be data-node CPU/IO**. If the bottleneck is aggregation on a single coordinator or a single connection, adding replicas does not solve it.
- The inflection point where linearity fades or reverses: **write-amplification backpressure** — the more replicas there are, the more replication traffic each insert creates (N copies) + a merge on each replica. Read-heavy and write-light → clean read scaling; write-heavy → adding replicas consumes read capacity instead. `QPS_max ≈ R × single-node concurrency / single-query duration`.
- Selecting the replica count:

| Replicas | Tolerated failures | Scenario |
|---|---|---|
| 1 | 0 | Pure dev / rebuildable |
| 2 | 1 | Minimum HA (⚠️ temporarily only 1 copy remains during a rolling restart) |
| **3** | 2 | **Production sweet spot** (2 redundant copies remain during a rolling restart; HA/cost balance) |
| 4 | 3 | Extremely high availability or extremely high read concurrency (usually added for read throughput; excessive for HA alone) |

- **Decision logic**: the number of replicas is driven by (1) how many simultaneous failures must be tolerated (including during rolling maintenance) + (2) read concurrency. **For HA alone, 3 is generally a sufficient ceiling**; beyond that, replicas are essentially being used for read scaling. Do not blindly pile on replicas for "more safety"; every copy adds proportional storage cost + write amplification.

---

## 4. Instance Type: ARM (Graviton) or x86? → ARM by Default

CK is one of the few workloads where ARM wins almost without qualification:
1. **Price/performance**: an equivalent Graviton configuration is about 20% cheaper, while CK scanning/aggregation is memory-bandwidth + integer/SIMD intensive. Graviton (especially the Neoverse V2 in r8g/i8g) delivers strong bandwidth and per-core throughput, so **cost per TB scanned** is usually significantly lower than x86.
2. **A first-class CK platform**: native aarch64 + NEON/SVE vectorized paths, and an Altinity-recommended platform. It is optimized, not merely "able to run."
3. **Energy efficiency/density**: advantageous for power costs and rack density in large clusters.

**The few exceptions that should remain on x86:**
- Dependency on **x86-only binaries**: CK executable UDF/dictionary, certain JDBC bridges, or third-party extension images without arm64 support.
- Workloads requiring extreme peak single-core frequency (rare; CK benefits from parallelism, not a single core).
- The team's images/CI are entirely x86 and it does not want to deal with multi-architecture builds in the short term.

**Conclusion: no hard x86 dependency → choose Graviton without hesitation.**

---

## 5. Storage: EBS gp3 vs Local NVMe (Instance Store)

| Dimension | EBS gp3 | Local NVMe (im4gn / i4g / i8g; x86 counterparts i4i/i7ie) |
|---|---|---|
| IO performance | Network block storage; sufficient | **Significantly stronger** (direct-attached PCIe, low latency, high IOPS) |
| Data durability | ✅ Volume is independent; if a node fails, reattach and use it | ❌ Node stop/termination/failure/underlying migration = data on disk is **permanently lost** and unrecoverable |
| Recovery from node failure | **Reattach the old volume in seconds** | **Minutes to hours** to reload all data from a replica |
| Recovery dependency on replicas | Weak (the volume remains) | **Strong; the only method**; a source replica must be alive |
| Cross-AZ / anti-affinity | Recommended | **Mandatory**, otherwise everything may be lost |
| Cost | Storage billed separately | Disk included in the instance price, often more cost-effective |

**Why local NVMe is often an upgrade for CK**: merges (continually combining parts in the background) and large-range scans are IO-heavy; local disk's low latency + high IOPS feed them directly, while also removing the hidden EBS network-bandwidth bottleneck (on large instance types, EBS throughput and network allowance are coupled).

**The fundamental tradeoff: the data is not durable.** Instance store shares the instance's lifecycle and is designed to be lost.

- **Starting out / prioritizing stability → gp3**: fast recovery and lower cognitive burden. 3 replicas + gp3 is the simplest production topology.
- **After hitting an IO wall (merge backlog, scans slowed by disk) → im4gn/i8g**, with these prerequisites welded in place: 3 replicas + strict distribution across 3 AZs + hostname anti-affinity + `karpenter.sh/do-not-disrupt` to prevent voluntary relocation.
- **To get both benefits → local NVMe for hot data + S3 tiering/backups for cold data** (see §7).

**⚠️ Only when the upstream lakehouse SoT in §7 is replayable can loss of local NVMe avoid authoritative data loss; however, local PVs still require manual release and recreation and are not "irrelevant."**

---

## 6. Let the Pod Consume the Entire EC2 Instance (One Node, One Pod)

**One EC2 instance = one CK pod is the recommended topology, not a compromise.** CK is "greedy": it consumes all CPU for parallelism, needs large contiguous RAM for aggregation, and depends heavily on the OS page cache to read compressed blocks. Co-locating it with other pods causes mutual interference (CPU contention, page-cache eviction, cross-node NUMA access), with low and unpredictable performance.

### Key pitfall: size against allocatable, not capacity
```
EC2 capacity (for example, m6g.8xlarge = 32 vCPU / 128 GiB)
  − kube-reserved + system-reserved (kubelet/containerd/OS)
  − eviction threshold (default ~100Mi)
  = Allocatable                      ← the maximum the scheduler can actually assign
  − DaemonSet usage (CNI/kube-proxy/EBS CSI/logging and monitoring agents)
  = what the CK pod can actually obtain
```
- **Do not hard-code `cpu:32 / memory:128Gi`** → the pod will remain Pending forever.
- Method: inspect **Allocatable** with `kubectl describe node`, subtract DaemonSet requests, and set the CK request **slightly below the net value**. (On m6g.8xlarge, allocatable memory is ~122Gi and CPU is ~31.x.)

### Four control levers
1. **Dedicated nodes** (taint + nodeSelector): taint the CK NodePool, and add a toleration + nodeSelector to the pod. Nothing except DaemonSets can compete for the node.
2. **One node, one pod** (`podAntiAffinity` + `topologyKey: kubernetes.io/hostname`, a hard `required` constraint): prevents two replicas from sharing one machine (if they do, the replicas are not redundant).
3. **CPU: high request, no limit**. CPU limit = CFS quota, which throttles parallelism at peak load; on a dedicated node with no competition, a limit is harmful. Set `requests.cpu` close to allocatable and **do not set a CPU limit**. CK is cgroup-aware: without a limit, it sizes the thread pool to the machine's full core count and consumes it correctly; with a limit, newer versions shrink the thread pool + suffer throttling. The cost is Burstable QoS (irrelevant on a dedicated node).
4. **Memory: request == limit, while leaving room for page cache**. Set `requests.memory == limits.memory` (memory should be Guaranteed to avoid eviction), but **do not fill allocatable completely** — CK reads compressed data through the OS page cache, and under cgroup v2, file pages also count toward container memory. Configure CK with `max_server_memory_usage_to_ram_ratio: 0.9`, capping query working memory at 90% of the cgroup limit and leaving 10% for page cache + overhead (CK reads the cgroup limit itself, so the ratio applies relative to the container limit).

### YAML Skeleton (Altinity CHI + Karpenter, Using m6g.8xlarge as the Example)
```yaml
# —— ClickHouseInstallation ——
spec:
  configuration:
    clusters:
      - name: default
        layout: { shardsCount: 1, replicasCount: 3 }   # 1 shard × 3 replicas
    settings:
      max_server_memory_usage_to_ram_ratio: "0.9"       # leave room for page cache
  defaults:
    templates: { podTemplate: ck, dataVolumeClaimTemplate: data }
  templates:
    podTemplates:
      - name: ck
        spec:
          tolerations:                                   # ① dedicated node
            - { key: dedicated, value: clickhouse, operator: Equal, effect: NoSchedule }
          nodeSelector: { workload: clickhouse }
          affinity:
            podAntiAffinity:                             # ② one node, one pod (hard constraint)
              requiredDuringSchedulingIgnoredDuringExecution:
                - topologyKey: kubernetes.io/hostname
                  labelSelector:
                    matchLabels: { clickhouse.altinity.com/chi: ck }
          containers:
            - name: clickhouse
              resources:
                requests: { cpu: "30", memory: 112Gi }   # ← slightly below allocatable (~31/~122)
                limits:   { memory: 112Gi }              # ← limit memory only, not CPU
    volumeClaimTemplates:
      - name: data
        spec:
          storageClassName: gp3
          accessModes: [ReadWriteOnce]
          resources: { requests: { storage: 500Gi } }
```
```yaml
# —— Karpenter NodePool ——
spec:
  template:
    metadata: { labels: { workload: clickhouse } }
    spec:
      taints:
        - { key: dedicated, value: clickhouse, effect: NoSchedule }
      requirements:
        - { key: karpenter.k8s.aws/instance-family, operator: In, values: ["m6g","r7g"] }
        - { key: karpenter.k8s.aws/instance-size,   operator: In, values: ["8xlarge"] }  # lock size to prevent downgrade
        - { key: kubernetes.io/arch,                 operator: In, values: ["arm64"] }
        - { key: topology.kubernetes.io/zone,        operator: In, values: ["us-east-1a","us-east-1b","us-east-1c"] }
  disruption:
    consolidationPolicy: WhenEmpty        # ⚠️ do not use WhenEmptyOrUnderutilized for a stateful DB
```

### Karpenter / EBS Pitfalls
- **Lock `instance-size`**, otherwise Karpenter may select a smaller instance based on requests or, when the request is too close to allocatable, jump to a larger instance.
- **Do not use `WhenEmptyOrUnderutilized` for `consolidationPolicy`**, or add `karpenter.sh/do-not-disrupt: "true"` to the pod — proactively consolidating and rescheduling a DB pod is disastrous.
- **EBS is AZ-bound**: when a pod is recreated, Karpenter must start a new machine in the PVC's AZ; the NodePool zone requirement must include that AZ, or recreation will be stuck.

### Node-Level Tuning (Outside the Pod Definition; Strongly Recommended by CK)
- Set THP to `madvise`; raise `nofile` to 500000+; disable swap. Apply these through the podTemplate's initContainer/securityContext, or use a tuning DaemonSet on the node.

---

## 7. Core Architectural Position: The Upstream Lakehouse Is the Sole SoT, and CK Is a Rebuildable Derived Serving Layer

**This is the key role that connects all the preceding tradeoffs.**

```
   ┌─────────────── Source of Truth ───────────────┐
   │  Lakehouse on S3 (Iceberg/Delta/Hudi/Parquet) │  ← authoritative, durable, complete, inexpensive
   │  + Glue Catalog                                │
   └───────────────────────┬────────────────────────┘
              ELT / scheduled sync / incremental ingestion
                            ▼
   ┌────────────────────────────────────────────────┐
   │  ClickHouse = derived, rebuildable query        │  ← hot data, sorted by MergeTree, serves BI
   │  acceleration layer; 1 shard × N replicas,      │
   │  local NVMe, consuming a full large machine     │
   └────────────────────────────────────────────────┘
```

**Mental-model shift: CK changes from an "authoritative database" to a "derived materialized acceleration layer." The data's home is the upstream lakehouse (usually S3-based); CK is only a copy optimized for queries. The clickhouse-backup S3 bucket in this repository is an auxiliary recovery point, not the lakehouse.** Once this role is accepted, all the tradeoffs follow:
- ✅ Loss of local NVMe does not cause authoritative data loss — after releasing the failed local PV, recovery can proceed from a healthy replica, and if necessary the data can be reloaded from the lakehouse (§5 converges here).
- ✅ DDL through CICD rebuilds the schema in seconds (DDL is instantaneous). Version the essence of tuning — `ORDER BY`/partition/codec/TTL — as code.
- ✅ **Two-level recovery**: fetch from a healthy replica after a partial failure (fast path); reload from the upstream lakehouse after total failure (authoritative slow path); ClickHouse S3 backups shorten RTO.
- ✅ The replica count can be based on "read QPS + online availability," while authoritative durability is the responsibility of the upstream lakehouse.
- ✅ It is even possible to run the cluster "on demand": start it for peak periods and scale it down while idle, because the data is in S3 anyway.

### Ingestion Methods for Importing from the Lakehouse into CK (Choose by SoT Form)
| SoT form | Recommended ingestion | Scenario |
|---|---|---|
| Raw Parquet written to an S3 prefix | `INSERT INTO ck SELECT * FROM s3(...)` | Bulk refill / one-off backfill |
| New files continuously written to S3 | **`S3Queue` engine** (native automatic consumption, analogous to Kafka offsets) | Near-real-time micro-batches |
| Open table formats Iceberg/Delta/Hudi | `iceberg()`/`deltaLake()`/`hudi()` table functions or engines, directly connected to Glue/REST catalog | The SoT is already a lakehouse table |
| Declarative scheduled pulls desired | **Refreshable Materialized View** (periodically refresh from s3()/iceberg()) | Make "sync from the lake" a DDL declaration, with no external orchestrator |
| Upstream is a stream | Kafka/MSK engine | Streaming-derived ingestion; long-term authoritative history still lands in the lakehouse |

⚠️ Maturity: `S3Queue`, refreshable MV, and Iceberg **writes** have only stabilized in the past year or two; reads are very stable, but check the changelog for write/exactly-once semantics against the cluster version.

### Distinguish Two Kinds of "Storage-Compute Separation" (We Choose the First)
- **(A) ELT copy** (this proposal): the lake is the SoT, and CK holds a MergeTree copy on fast local disk. Recovery = reload. Fast queries, authoritative lake, simple operations. **For a lightweight BI serving layer → this is almost always better.**
- **(B) Native CK S3 disk + zero-copy**: data lives directly in S3, nodes are pure compute+cache, and recovery = repointing, with no reload. Maximum elasticity, but cold reads incur S3 latency and operations are heavier.

### 4 Things the Implementation Must Get Right
1. **Idempotency / deduplication** (the lifeline of replay):
   - Replay by partition: `PARTITION BY toYYYYMMDD(...)`; during recovery, `DROP PARTITION` and then perform a clean reinsert instead of redoing the entire table.
   - Block-level deduplication (`insert_deduplicate`, with Keeper recording hashes of recently inserted blocks) prevents duplicate identical blocks.
   - Row-level upsert → `ReplacingMergeTree`.
   - Record a watermark / high-water mark so you know what has been ingested and where to resume replay; do not perform a full reload every time.
2. **Incremental, not full**: recovery from a node failure should not replay all history — replicas cover recent hot data + S3 replays only affected/recent partitions. Reserve a full reload for the true disaster where "all replicas of an entire shard are gone simultaneously." Partition design determines whether only a small slice can be replayed.
3. **Manage schema drift**: Iceberg schema evolution does **not automatically propagate** to CK (CK is a downstream copy); column additions/removals and type changes require explicit mapping in CICD. Lock `ORDER BY`/codec in version control so a rebuild is byte-for-byte consistent.
4. **Put consistency lag in the SLA**: CK is derived downstream from the lake → eventually consistent; BI sees the "last synchronization point." The role allows this, but freshness = X minutes must be stated explicitly; do not let users assume it is real time.

---

## 8. Recovery Comparison: Replica Fetch vs S3 Reload

**The root cause of the difference is not data volume, but "the work being done":**
```
Inter-replica recovery (fetch): copy [ready-made MergeTree parts] — bytes already sorted/compressed/indexed
                                → network file copy, with almost no CPU work (interserver port 9009,
                                  sent as-is, with no decompression/resorting)
S3 reload recovery (re-ingest): read Parquet → [sort again + compress again + rebuild sparse indexes + merge small parts]
                                → CPU/IO-intensive full rebuild; parts are created from scratch
```

| | Replica fetch | S3 reload |
|---|---|---|
| Object processed | Ready-made compressed parts | Read Parquet + rebuild into parts |
| Bottleneck | Network bandwidth | CPU (sorting+compression) + S3 read bandwidth |
| Effective rate (rough) | ~500 MB/s – GB/s network-class | ~100–300 MB/s output-class (limited by core count) |
| Estimated time for 500 GiB | **~10–20 minutes** | **~40 minutes – 2 hours** |
| Order of magnitude | Baseline | **About one order of magnitude slower** |

- ⚠️ The numbers are order-of-magnitude estimates (for narrative purposes, not commitments); actual results depend on parallelism, network, S3 bandwidth, part fragmentation, and instance compute.
- **RTO breakdown (recovery from total failure using S3)**: Karpenter starts nodes (a few minutes) + DDL creates tables (seconds ✅) + **read from S3 + rebuild MergeTree (the long pole, tens of minutes to hours)**. Do not treat S3 recovery as "fast failover"; it is an "acceptable DR RTO."

### Impact During Replica Recovery (Calibrating the "Only QPS Decreases" Claim)
- ✅ **The read-QPS ceiling falls**: 3→2 remain in service, so read capacity drops by ~1/3. The direction is correct.
- ⚠️ **But it is not clean — the source replica does double duty**: the replica acting as the source both serves queries and pushes parts outward, slowing its own query latency. The overall decline is more pronounced than simply "one fewer machine."
- ✅ **Unaffected**: writes are uninterrupted (new writes queue and catch up together); query correctness is unaffected (the lagging replica is not routed to, controlled by `max_replica_delay_for_distributed_queries`); there is no write pause/split brain/inconsistency.
- ➕ **Redundancy is temporarily degraded**: 3→2; if another machine fails during this window, only 1 remains. The longer recovery takes, the longer the unprotected window. This is an availability risk and the real reason "recovery must be fast."

### Control Knobs: Recovery Speed ↔ QPS Protection
- `max_replicated_fetches_network_bandwidth_for_server`: cap recovery-traffic bandwidth, reserving bandwidth for queries (trade recovery speed for stable QPS).
- `background_fetches_pool_size`: number of parallel fetch threads; increase it to accelerate recovery (but consume more source-replica IO).
- Usage: failure during peak traffic → throttle to protect QPS and let recovery take longer; off-peak → open the bandwidth to escape the 2-replica unprotected state as soon as possible. (The S3-reload path has a corresponding knob: ingestion concurrency vs query resources, but the replica path is more granular and commonly used.)

---

## 9. To Be Verified / Version-Dependent (Do Not Treat as Settled; Confirm Against the Actual Cluster)

- Maturity and exactly-once semantics of `S3Queue` / refreshable MV / Iceberg writes — pin the version and check the changelog.
- Stability and enablement method of `parallel_replicas` — becoming stable in recent versions.
- The reference stack's actual `clickhouse-cluster.yaml`: whether `internal_replication` is `true` (**must** be true when using a Replicated engine, otherwise Distributed writes + engine replication = duplicate writes; the Operator gets it right by default, but this is the number-one pitfall in self-built clusters); actual AZ topology spread / anti-affinity values; where the `<zookeeper>` section points.
- Exact allocatable values vary with EKS version / AMI / DaemonSet; measure with `kubectl describe node` before deployment.

---

## 10. Guiding Principle in One Sentence

**The upstream lakehouse holds the sole SoT + CK is a rebuildable materialized serving layer; start with 1 shard × 3 replicas on large Graviton nodes, one node per pod consuming the whole machine (request≈allocatable, no CPU limit, memory request==limit + ratio 0.9); switch to local NVMe after hitting an IO wall; DDL as code; two-level recovery — healthy-replica fetch is the fast path, lakehouse reload is the authoritative slow path, and ClickHouse S3 backups shorten RTO. Introduce sharding only after hitting "a single query can use only one machine's compute / the full dataset cannot fit on one machine"; before that, use parallel_replicas first.**
