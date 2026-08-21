# ClickHouse on EKS — Production Best-Practices Notes (2026-07)

[中文](./notes-ck-on-eks-best-practices-2026.md) · **English**

> Background: starting from the awslabs data-on-eks clickhouse-on-eks reference stack (Altinity Operator + Keeper + Karpenter + ArgoCD, with a 3×3 example), this document derives deployment recommendations for this project's data role and operational boundaries.
> Reference page: https://awslabs.github.io/data-on-eks/docs/datastacks/databases/clickhouse-on-eks

---

## 0. Applicability Boundaries

These recommendations target a specific data role: the upstream data lakehouse holds the sole authoritative Source of Truth, while CK is its downstream, derived, eventually consistent, rebuildable OLAP / BI serving acceleration layer.

The recommendations apply only within this role. Reevaluate the storage, sharding, and replica strategy in the following situations:

- CK must be the **primary store / sole SoT** (with no upstream lakehouse fallback) → durability requirements rise sharply, the local-NVMe approach no longer works, and the design must return to EBS + backups as the foundation.
- **Extremely high-throughput real-time ingestion** (such as large-scale direct Kafka ingestion, with writes outweighing reads) → write amplification becomes the primary constraint, and both replica and sharding strategies must be reevaluated.
- **Very large scale, where a single query must fan out across many machines** → true sharding is mandatory; 1-shard scale-up cannot handle it.

This document therefore covers deployment recommendations for CK as a lakehouse-derived serving layer on EKS, not every ClickHouse-on-EKS scenario.

---

## 1. Topology Fundamentals

### shard = horizontal partitioning by rows, not by columns
- Each shard stores a **subset of the table's rows**, with the same schema; only their union forms the complete table.
- CK is columnar, but "columnar storage" means that data is organized by column **on disk within a single node**; "sharding" means partitioning by row **across nodes**. These are two orthogonal dimensions. **There is no column-level sharding.**
- The hash of the sharding key determines which shard receives a row (the reference uses `cityHash64(UserID)`). Distribution is approximately balanced, **not guaranteed to be exactly even** — skewed keys can make one shard oversized.
- The minimum shard count is **1** (0 does not exist). Any positive integer is valid (2/4/7…).

### replica = a complete copy of the same shard, multi-master, with no primary/secondary
- **Model clarification**: CK's ReplicatedMergeTree is **multi-master and peer-to-peer (masterless)**, not the primary-replica model used by MySQL/PG/Redis.
  - There is no "primary replica" role, **no primary/secondary election, and no failover promotion**.
  - Every replica can read and write; if one goes down, the others continue normally, and after restart it reconciles with Keeper and catches up by itself.
  - (Historical baggage: old versions had a "leader" that only scheduled merges and had nothing to do with reads or writes; after 20.5 there are multiple leaders, so that bottleneck has largely disappeared. Do not impose the "primary/secondary" model on CK.)
- Replica counts have **no odd/even requirement** (2/4 are both valid). ⚠️ Do not confuse this with **Keeper** — Keeper uses Raft and needs an odd number (3/5) to form a quorum; **data replicas do not use quorum** (replication is asynchronous by default).

### What Each Dimension Solves
```
Want one "query" to run faster / store more data  →  add SHARDS (horizontal partitioning, by row)
Want to handle more "concurrent queries" / keep serving through failures  →  add REPLICAS (redundancy, multi-master peers)
```

### Analogy with Kafka/MSK
```
Kafka partition  ≈  CK SHARD    ← parallelism/partitioning unit
Kafka replica    ≈  CK REPLICA  ← redundancy unit
```
- Parallelism comes from shards, not replicas (as with Kafka: parallelism comes from the number of partitions).
- **Difference**: Kafka followers do not serve clients by default (follower reads arrived only with KIP-392); **all CK replicas are readable**.

---

## 2. Recommended Starting Point: 1 Shard × 3 Replicas + Large Nodes (Scale Up First)

This project defaults to scaling up a single node and introduces sharding only after reaching a capacity or single-query compute limit, for two reasons:
- A single CK node can hold terabytes of compressed data; the practical capacity depends on query shape and storage configuration.
- **Re-sharding has significant operational cost**: CK has no automatic rebalance; after adding a shard, historical data does not move automatically and must be reloaded manually with `INSERT SELECT` or `clickhouse-copier`.

Therefore, the recommended default topology is: **no sharding (`shardsCount: 1`) + 3 replicas + each replica exclusively occupies one large Graviton, spread across 3 AZs.**

```
        replica r1        replica r2        replica r3
       ┌──────────┐      ┌──────────┐      ┌──────────┐
       │ large pod│ ≈≈≈  │ large pod│ ≈≈≈  │ large pod│   full data × 3 complete copies
       │  AZ-a    │      │  AZ-b    │      │  AZ-c    │
       └──────────┘      └──────────┘      └──────────┘
   1 shard = every node has the full table, with no horizontal partitioning; each pod exclusively occupies one EC2 instance
```

**Reasons for this default topology:**
- ✅ No re-sharding is required initially.
- ✅ No cross-shard fan-out or coordinator overhead for aggregating multiple shards.
- ✅ HA + read scaling are both in place: if 1 machine fails, 2 copies remain; read QPS is approximately 3×.
- ✅ The scaling paths are explicit: add replicas when read throughput is insufficient, or select a larger instance type when single-node resources are insufficient. Neither changes data partitioning.

**Two topology constraints:**
1. **A `Replicated` engine requires Keeper**. Replication coordination is independent of the shard count, so a 1×3 topology still needs a 3-node Keeper ensemble.
2. **A Distributed table is usually unnecessary with 1 shard**. Each replica holds all data, so clients can query local ReplicatedMergeTree tables through an LB that distributes connections across the 3 pods. A Distributed table adds an extra forwarding hop.

**Conditions for introducing shards:**
1. The complete dataset no longer fits on one node (compressed data exceeds a single machine's disk / the maximum EBS/NVMe attachable to an instance type).
2. **A single large aggregation is too slow** — with 1 shard, one query can use only one machine's compute; replicas do not accelerate a single query. Heavy aggregations that scan most of a table will be bottlenecked by one machine's CPU. (The most common hidden limit.)
3. Ingestion throughput exceeds one node's limit (less common).

**Evaluate `parallel_replicas` before sharding**. Once enabled, a query can call multiple replicas of the same shard to scan data in parallel, increasing single-query parallelism. In a 1-shard topology, this can mitigate a single-query compute limit, but the benefit depends on query type and introduces coordination overhead. Validate it on the pinned version and check the changelog before enabling it.

---

## 3. Quantitative Sizing

### Number of shards vs data volume
The shard count must account for three constraints:
```
shards = max( storage-driven, single-query-latency-driven, ingestion-driven )
```
1. **Storage-driven**: `shards = ceil(total compressed data volume / target capacity per shard)`. The target capacity of a single shard depends on the query shape:
   - Good index selectivity (point lookups/filters on leading columns, scanning only a few granules) → a single node can reach **tens of TB**; capacity is constrained by disk, not queries.
   - Scan/aggregation-heavy (large-range GROUP BY) → consider sharding at **1–4 TB**, because the amount scanned by one query ∝ the amount of data on one node.
   - ⚠️ Calculate using the **compressed** size (CK typically achieves 5–10× compression) to avoid over-sharding based on raw volume.
2. **Single-query-latency-driven**: fan-out width = number of shards; scanning N rows across K shards → each scans N/K, for approximately linear speedup. Work backward from "this large aggregation must finish within X seconds" to determine the required parallelism.
3. **Ingestion-driven**: a single node can insert hundreds of MB/s to GB/s, so this is usually not the binding constraint.

- Total nodes = `shards × replicas`; each machine stores `total volume/shards` (not /number of nodes, because replicas are complete copies).
- Recommendation: scale up a single node first and add shards after reaching a storage or scan limit. Choose the shard count that satisfies both storage and latency constraints, and reserve capacity because re-sharding generally has a higher operational cost than provisioning headroom.

### Number of replicas vs QPS
- **Read QPS can grow approximately linearly with the number of replicas**, and the read path does not use Keeper (Keeper is used on write and DDL paths).
- Two prerequisites for obtaining linear scaling:
  1. **Concurrency must be distributed across replicas**: use `load_balancing` (the default in newer versions is `random`) + **spread client connections across all nodes** (put an LB in front for round-robin). Otherwise, all connections pressure the same coordinator, hit its aggregation bottleneck first, and additional replicas are useless.
  2. **The bottleneck must be data-node CPU/IO**. If the bottleneck is aggregation on a single coordinator or a single connection, adding replicas does not solve it.
- The inflection point where linearity fades or reverses: **write-amplification backpressure** — the more replicas there are, the more replication traffic each insert creates (N copies) + a merge on each replica. Read-heavy and write-light → clean read scaling; write-heavy → adding replicas consumes read capacity instead. `QPS_max ≈ R × single-node concurrency / single-query duration`.
- Selecting the replica count:

| Replicas | Tolerated failures | Scenario |
|---|---|---|
| 1 | 0 | Pure dev / rebuildable |
| 2 | 1 | Minimum HA (⚠️ temporarily only 1 copy remains during a rolling restart) |
| **3** | 2 | Common production configuration (2 redundant copies remain during a rolling restart) |
| 4 | 3 | Extremely high availability or extremely high read concurrency (usually added for read throughput; excessive for HA alone) |

- **Decision logic**: the number of replicas is driven by (1) the required simultaneous-failure tolerance, including rolling maintenance, and (2) read concurrency. Three replicas are common when HA is the only objective; additional replicas mainly provide read scaling and add proportional storage cost and write amplification.

---

## 4. Instance Type: ARM (Graviton) or x86? → ARM by Default

This project defaults to ARM when there is no architecture-specific dependency:
1. **Price/performance**: an equivalent Graviton configuration is about 20% cheaper. CK scanning and aggregation depend on memory bandwidth and integer/SIMD performance, so Graviton, especially Neoverse V2 in r8g/i8g, can reduce **cost per TB scanned**. The actual difference still requires testing with the target queries.
2. **Software support**: ClickHouse provides native aarch64 and NEON/SVE vectorized paths, and Altinity lists ARM as a recommended platform.
3. **Energy efficiency/density**: advantageous for power costs and rack density in large clusters.

**The few exceptions that should remain on x86:**
- Dependency on **x86-only binaries**: CK executable UDF/dictionary, certain JDBC bridges, or third-party extension images without arm64 support.
- Workloads requiring extreme peak single-core frequency (rare; CK benefits from parallelism, not a single core).
- The team's images/CI are entirely x86 and it does not want to deal with multi-architecture builds in the short term.

**Conclusion:** when there are no x86-only binary or toolchain constraints, evaluate Graviton first and confirm the choice with the target workload.

---

## 5. Storage: EBS gp3 vs Local NVMe (Instance Store)

| Dimension | EBS gp3 | Local NVMe (im4gn / i4g / i8g; x86 counterparts i4i/i7ie) |
|---|---|---|
| IO performance | Network block storage; sufficient | **Significantly stronger** (direct-attached PCIe, low latency, high IOPS) |
| Data durability | ✅ Volume is independent; if a node fails, reattach and use it | ❌ Node stop/termination/failure/underlying migration = data on disk is **permanently lost** and unrecoverable |
| Recovery from node failure | **Reattach the old volume in seconds** | **Minutes to hours** to reload all data from a replica |
| Recovery dependency on replicas | Weak (the volume remains) | **Strong; the only method**; a source replica must be alive |
| Cross-AZ / anti-affinity | Recommended | **Mandatory**, otherwise everything may be lost |
| Cost | Storage billed separately | Disk included in the instance price; compare total monthly instance and volume cost |

**Performance benefits of local NVMe**: merges and large-range scans are I/O-intensive. Local disk can reduce storage wait through lower latency and higher IOPS, and it is not limited by the instance EBS channel. The benefit depends on whether the working set fits in page cache and whether the workload is persistently storage-bound.

**The fundamental tradeoff: the data is not durable.** Instance store shares the instance's lifecycle and is designed to be lost.

- **Default to gp3**: replacement nodes can reattach the original volume, reducing recovery work. Three replicas + gp3 applies when lower operational complexity is the priority.
- **Evaluate im4gn/i8g when storage is a sustained bottleneck**, with these prerequisites: 3 replicas, strict distribution across 3 AZs, hostname anti-affinity, and `karpenter.sh/do-not-disrupt` to prevent voluntary relocation.
- **Tiered option**: local NVMe for hot data and S3 tiering or backups for cold data (see §7).

**⚠️ Only when the upstream lakehouse SoT in §7 is replayable can loss of local NVMe avoid authoritative data loss; however, local PVs still require manual release and recreation and are not "irrelevant."**

---

## 6. Let the Pod Consume the Entire EC2 Instance (One Node, One Pod)

This project runs **one CK Pod per EC2 instance**. ClickHouse uses substantial CPU parallelism, aggregation memory, and OS page cache. Co-location with other workloads introduces CPU contention, page-cache eviction, and cross-node NUMA access, increasing performance variance.

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
- **Do not use `WhenEmptyOrUnderutilized` for `consolidationPolicy`**, or add `karpenter.sh/do-not-disrupt: "true"` to the Pod. Proactive relocation of a stateful database Pod triggers unnecessary recovery work.
- **EBS is AZ-bound**: when a pod is recreated, Karpenter must start a new machine in the PVC's AZ; the NodePool zone requirement must include that AZ, or recreation will be stuck.

### Node-Level Tuning (Outside the Pod Definition; Strongly Recommended by CK)
- Set THP to `madvise`; raise `nofile` to 500000+; disable swap. Apply these through the podTemplate's initContainer/securityContext, or use a tuning DaemonSet on the node.

---

## 7. Data Role: The Upstream Lakehouse Is the Sole SoT, and CK Is a Rebuildable Derived Serving Layer

The following data role is the common premise for the storage and recovery strategies above.

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

CK does not act as the authoritative database; it is a derived, materialized acceleration layer for lakehouse data. The upstream lakehouse, usually based on S3, retains authoritative data, while CK stores a query-optimized copy. The clickhouse-backup S3 bucket in this repository is an auxiliary recovery point, not the lakehouse. Under this premise:
- ✅ Loss of local NVMe does not cause authoritative data loss — after releasing the failed local PV, recovery can proceed from a healthy replica, and if necessary the data can be reloaded from the lakehouse (§5 converges here).
- ✅ DDL through CICD rebuilds the schema in seconds (DDL is instantaneous). Version the essence of tuning — `ORDER BY`/partition/codec/TTL — as code.
- ✅ **Two-level recovery**: fetch from a healthy replica after a partial failure (fast path); reload from the upstream lakehouse after total failure (authoritative slow path); ClickHouse S3 backups shorten RTO.
- ✅ The replica count can be based on "read QPS + online availability," while authoritative durability is the responsibility of the upstream lakehouse.
- ✅ On-demand cluster operation can be evaluated, but scale-down policies must account for local-NVMe data loss, reload time, and recovery cost.

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
- **(A) ELT copy** (this proposal): the lake is the SoT, and CK holds a MergeTree copy on fast local disk. Recovery uses reload. This applies to BI serving workloads that prioritize query latency and can accept the reload RTO.
- **(B) Native CK S3 disk + zero-copy**: data lives directly in S3, nodes are pure compute+cache, and recovery = repointing, with no reload. Maximum elasticity, but cold reads incur S3 latency and operations are heavier.

### 4 Things the Implementation Must Get Right
1. **Idempotency / deduplication** (to keep replay results consistent):
   - Replay by partition: `PARTITION BY toYYYYMMDD(...)`; during recovery, `DROP PARTITION` and then perform a clean reinsert instead of redoing the entire table.
   - Block-level deduplication (`insert_deduplicate`, with Keeper recording hashes of recently inserted blocks) prevents duplicate identical blocks.
   - Row-level upsert → `ReplacingMergeTree`.
   - Record a watermark / high-water mark so you know what has been ingested and where to resume replay; do not perform a full reload every time.
2. **Prefer incremental recovery**: node-failure recovery should not replay all history by default. Replicas recover recent hot data, and S3 replays only affected or recent partitions. Perform a full reload only when all replicas of an entire shard are lost. Partition design determines whether recovery can be limited to a small range.
3. **Manage schema drift**: Iceberg schema evolution does **not automatically propagate** to CK (CK is a downstream copy); column additions/removals and type changes require explicit mapping in CICD. Lock `ORDER BY`/codec in version control so a rebuild is byte-for-byte consistent.
4. **Put consistency lag in the SLA**: CK is derived downstream from the lake → eventually consistent; BI sees the "last synchronization point." The role allows this, but freshness = X minutes must be stated explicitly; do not let users assume it is real time.

---

## 8. Recovery Comparison: Replica Fetch vs S3 Reload

The two recovery paths process different data forms and perform different computation:
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
- **RTO breakdown (full recovery using S3)**: Karpenter starts nodes (a few minutes) + DDL creates tables (seconds) + **read from S3 and rebuild MergeTree (typically tens of minutes to hours)**. S3 reload is a DR recovery path, not fast failover.

### Impact During Replica Recovery (Calibrating the "Only QPS Decreases" Claim)
- ✅ **The read-QPS ceiling falls**: 3→2 remain in service, so read capacity drops by ~1/3. The direction is correct.
- ⚠️ **The source replica carries both query and recovery traffic**: while serving queries, it also transfers parts, which can increase query latency. The capacity reduction can therefore exceed the effect of losing one replica alone.
- ✅ **Unaffected**: writes are uninterrupted (new writes queue and catch up together); query correctness is unaffected (the lagging replica is not routed to, controlled by `max_replica_delay_for_distributed_queries`); there is no write pause/split brain/inconsistency.
- ➕ **Redundancy is temporarily degraded**: after 3→2, another replica loss during recovery leaves only 1 replica. Shorter recovery reduces this risk window.

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

## 10. Design Summary

The upstream lakehouse holds the sole SoT, and CK is a rebuildable materialized serving layer. The default topology is 1 shard × 3 replicas on large Graviton nodes, with one Pod per node (request near allocatable, no CPU limit, memory request equal to limit, and ratio 0.9). Evaluate local NVMe when storage becomes a sustained bottleneck, and manage DDL as code. Partial failures recover through healthy-replica fetch; loss of all replicas uses lakehouse reload, with ClickHouse S3 backups reducing RTO. Introduce sharding when single-query compute or single-node capacity reaches its limit; before that, validate `parallel_replicas` for the target queries.
