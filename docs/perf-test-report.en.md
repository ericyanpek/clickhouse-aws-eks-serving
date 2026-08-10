# ClickHouse on EKS - Performance Test Report

[中文](./perf-test-report.md) · **English**

> Test date: 2026-07-05
> Dataset: ClickBench `hits` (Yandex Metrica web analytics, 99,997,497 rows, a single wide table with 105 columns)
> Conclusion first: **On a 1-shard × 2-replica topology with 2× i8g.4xlarge instances (local NVMe), the 43 ClickBench queries took 18.76s in total for best-of-3 runs, averaging 0.436s with a median of 0.175s. Read QPS differed by 1-2 orders of magnitude depending on query weight (full-table scan and aggregation: ~48; indexed point lookup: ~2,780); concurrency from 1→2 achieved nearly perfect linear scaling (2.0×); heavy scan queries could be accelerated by up to another 1.8× with `parallel_replicas`; and when one replica failed, service continued without interruption, QPS fell by approximately 50%, and the replica self-healed in approximately 65s.**
>
> **Status note:** This is a historical record of actual measurements from the 1×2 environment, and its original basis must be preserved. The current code targets 1×3; until testing with 3 replicas is complete, the linear extrapolations in this document must not be presented as measured 1×3 results. See [`docs/README.en.md`](./README.en.md) for the current authority level of this document.

---

## 1. Test Environment

| Item | Configuration |
|---|---|
| Platform | Amazon EKS 1.34 (platform eks.27), us-east-1 |
| ClickHouse | 25.3.14.14, Altinity operator 0.27.1 |
| Topology | **1 shard × 2 replicas** (ReplicatedMergeTree), 3-node ClickHouse Keeper |
| Data nodes | 2 × **i8g.4xlarge** (16 vCPU / 128 GiB / Graviton4), 1 Pod each, across AZs (1a/1b) |
| Storage | **Local NVMe instance store ~3.75TB** (not EBS), local-static-provisioner |
| Keeper | 3 × m7g.large (non-burstable Graviton), across 3 AZs, gp3 |
| Load generator | Dedicated c7g.2xlarge (`system-bench` node, isolated with taints, does not compete with ClickHouse for resources) |
| Access | ClusterIP service `clickhouse-ch` (round-robin across 2 replicas within the cluster) |
| Resource model | CPU request 14 / no limit; memory request==limit 110Gi; `max_server_memory_usage_to_ram_ratio=0.9` |

> Note: Due to fluctuations in i8g.4xlarge spot capacity in us-east-1, the current environment has **2 replicas** (target: 3). Test conclusions are reported on the basis of 2 replicas; read scaling to 3 replicas can be extrapolated linearly.

### Dataset and Storage Efficiency

| Metric | Value |
|---|---|
| Row count | 99,997,497 (~100 million) |
| Uncompressed | 50.62 GiB |
| On disk (compressed) | **13.45 GiB** |
| **Compression ratio** | **3.8×** |
| Data location on disk | `/var/lib/clickhouse/` (local NVMe)|
| Replication lag (after loading) | 0 |

---

## 2. Phase 1: Single-Node Query Latency (43 ClickBench Queries)

Each query was run 3 times and the best result was used (the standard ClickBench warm-run methodology), with a single connection (concurrency=1).

### Summary

| Metric | Value |
|---|---|
| Total queries | 43 |
| Total elapsed time (sum of best runs) | **18.76s** |
| Average | 0.436s |
| Median (p50) | 0.175s |
| p90 | 1.268s |
| Fastest (Q1 `COUNT(*)`) | 0.002s |
| Slowest (Q29) | 5.211s |

### Distribution Characteristics

- **Approximately 65% of queries completed in under one second** (<0.3s). Point lookups and queries filtering on leading columns hit the sparse index and returned in milliseconds.
- **A small number of scan-intensive queries mark the single-node compute ceiling** (see below). They scan a broad range of columns and perform high-cardinality aggregation, and are limited by single-node CPU.

### Five Slowest Queries (Single-Node Scan Ceiling)

| Query | best (s) | Characteristics |
|---|---|---|
| Q29 | 5.211 | Heavy aggregation over a broad range of URL/regex-related data |
| Q19 | 1.665 | High-cardinality GROUP BY |
| Q24 | 1.347 | Multi-column scan and aggregation |
| Q34 | 1.284 | Wide scan + sorting |
| Q35 | 1.268 | Wide scan + sorting |

> See [`docs/perf-results/clickbench-43queries.csv`](./perf-results/clickbench-43queries.csv) for the complete per-query data.

---

## 3. Phase 2: Single-Query Acceleration with parallel_replicas (Heavy Queries)

`parallel_replicas` was enabled for the slowest queries (2 replicas scanning the same data in parallel) to validate the design proposition of "use parallel_replicas before sharding."

Settings: `allow_experimental_parallel_reading_from_replicas=2, max_parallel_replicas=2, cluster_for_parallel_replicas='main'`

| Query | Disabled (s) | Enabled (s) | Result |
|---|---|---|---|
| **Q24** | 1.337 | 0.737 | **1.81× speedup** ✅ |
| **Q29** (heaviest) | 5.269 | 3.958 | **1.33× speedup** ✅ |
| Q19 | 1.778 | 2.489 | 0.71× (slower) ⚠️ |
| Q33 | 1.232 | 2.669 | 0.46× (slower) ⚠️ |
| Q34 | 1.392 | 4.627 | 0.30× (slower) ⚠️ |

### Conclusion (Candidly, Not Every Query Was Accelerated)

- **Effective for large scan/aggregation queries (Q24/Q29):** 2 replicas shared the scan volume, accelerating a single query by 1.3-1.8×. This validates that `parallel_replicas` can postpone the introduction of sharding when the "single-query compute ceiling" is reached.
- **Lightweight queries, queries with LIMIT, and queries sensitive to coordination overhead became slower instead:** the fixed overhead of parallel coordination exceeded the benefit from scanning.
- **Practical recommendation:** `parallel_replicas` should be **enabled selectively by query** (for known heavy scan queries), rather than enabled globally by default.

---

## 4. Phase 3: Read Concurrency / QPS Scaling

> ⚠️ **First, one critical point must be clear:** QPS is not a fixed metric of a cluster; it is **a function of query complexity**. Section 4.1 uses one heavy "full-table scan and aggregation" query to measure the **linearity of replica read scaling** (so the QPS value is low, only in the dozens); Section 4.2 adds actual QPS measurements for queries of different weights (point lookups can reach thousands). **Do not treat the ~52 QPS in Section 4.1 as the cluster's throughput ceiling** - it is the lower bound for the heaviest query.

### 4.1 Linearity of Read Scaling (Using a Heavy Full-Table Scan Query)

From the dedicated benchmark node, `clickhouse-benchmark` targeted the ClusterIP service (round-robin across 2 replicas). The query was a full-table `GROUP BY RegionID` (a heavy aggregation that **scans all 100 million rows on every execution**). Steady-state QPS at concurrency levels from 1→16:

| Concurrency | Steady-state QPS | Relative to c=1 | Notes |
|---|---|---|---|
| 1 | ~22.5 | 1.0× | Single-connection baseline |
| 2 | ~44.8 | **2.0×** | **Nearly perfect linear scaling - read scaling across 2 replicas is working** |
| 4 | ~50.5 | 2.2× | Beginning to saturate |
| 8 | ~52 | 2.3× | Saturated |
| 16 | ~52 | 2.3× | Saturated (no further improvement) |

Peak scan throughput: **~5 billion rows/second, ~20 GiB/s** (RPS/bandwidth, local NVMe + vectorized scanning).

**Read scaling conclusions:**

- **Concurrency from 1→2 achieved nearly perfect linear scaling (2.0×):** this validates that read QPS scales linearly with replica count and that ClusterIP round-robin distributes load evenly across 2 replicas.
- **Saturation at ~52 QPS after concurrency 4:** because the test query performs a full-table scan and aggregation (scanning 100 million rows per query), **the CPUs of the 2 i8g instances are fully utilized at approximately 4 concurrent queries** - exactly illustrating that "read throughput ceiling = number of replicas × single-node concurrency capacity." For this kind of heavy scan workload, the way to raise the QPS ceiling is to **add replicas** (linearly).
- Peak scan throughput was **~5 billion rows/second, ~20 GiB/s:** measured as "rows scanned per second (RPS)," the scan capacity of 2 i8g instances is extremely high - **QPS is only 52 because each query scans so many rows, not because the cluster is weak**.
- Extrapolation: with 3 replicas, the expected saturation QPS would be approximately ~75 (linear extrapolation).

### 4.2 Actual QPS for Different Query Types (Concurrency 8)

On the same cluster, QPS differed by 1-2 orders of magnitude depending on query weight. Almost all real BI/serving workloads include filters (time ranges, dimensions), hit the ClickHouse sparse primary-key index (the primary key of this table is `CounterID, EventDate, ...`), and scan only a small portion of the data, so QPS is far higher than for a full-table scan. Measured results:

| Query type | QPS | RPS (rows scanned per second) | Notes |
|---|---|---|---|
| **Pure connection overhead** (`SELECT 1`, no scan) | **~5,860** | — | Cluster request-processing ceiling |
| **Point lookup** (`WHERE CounterID=?`, hits primary-key index) | **~2,780** | 44 million | Scans only the data block for that key - ~58× higher than a full-table scan |
| **Filtered aggregation** (GROUP BY after hitting the index, typical BI) | **~370** | 3.15 billion | Typical range for production serving workloads |
| **Full-table aggregation** (the heavy query from §4.1, for comparison) | **~48** | 4.8 billion | Scans all 100 million rows every time |

> Raw log: [`docs/perf-results/qps-by-query-type.txt`](./perf-results/qps-by-query-type.txt)

**Key conclusions:**

1. **QPS is determined by query complexity; it is not a fixed property of the cluster:** on the same cluster, changing a query from a "full-table scan" to an "indexed lookup" increased QPS from ~48 to ~2,780 (**58×**).
2. **RPS (rows scanned per second) better reflects actual hardware capability:** although full-table aggregation delivered only 48 QPS, RPS reached 4.8 billion rows/second - scan throughput was extremely high; each individual query simply did a large amount of "work."
3. **Real serving/BI workloads fall in the range between point lookups and filtered aggregations (hundreds to thousands of QPS),** not the dozens produced by full-table scans. Instance selection and capacity planning should measure QPS using the **actual shape of the target queries**; full-table scan numbers cannot represent cluster capacity.

---

## 5. Phase 4: HA Chaos Test (Killing a Replica Under Read Load)

Under continuous read load (concurrency 4, `--continue_on_errors`), one replica Pod, `chi-ch-main-0-1-0`, was killed to observe service continuity and recovery.

| Phase | QPS | Errors | Service status |
|---|---|---|---|
| Before kill (2 replicas) | ~47-48 | 0 | Normal |
| **At the moment of the kill** | — | **Only 1** (in-flight query) | Uninterrupted |
| After kill (1 replica) | ~25-26 | 0 (subsequent) | **Continuously available** |
| After recovery | Recovered | 0 | 2 replicas |

- **Replica self-healing time: approximately 65 seconds** (Pod recreation + data still present on local NVMe, enabling rapid recovery).
- Note: In this test, **the Pod was killed while the node remained alive**, so the local NVMe data volume was still present and recovery was extremely fast. If the **entire node were lost** (and the local disk with it), a full rebuild from a surviving replica would be required (on the order of minutes, depending on data volume). This is an inherent tradeoff of the local NVMe design.

### Conclusion

The HA design was fully validated: **single-replica failure → QPS fell by approximately 50% (2→1), service remained available, only 1 instantaneous query was lost, and the replica self-healed in approximately 65s**. This is consistent with the ReplicatedMergeTree characteristics of "multi-primary peer replication, no primary/secondary election, and the remaining replicas continue as normal when one fails."

---

## 6. Overall Conclusions

| Dimension | Result | Design proposition validated |
|---|---|---|
| Single-node query performance | 43 queries averaged 0.436s; 65% completed in under one second | i8g + local NVMe + vectorized scanning, a sweet spot for wide-table OLAP |
| Compression efficiency | 3.8× | Columnar storage + compression |
| Single-query ceiling | Slowest was 5.2s (Q29); heavy scans were limited by single-node CPU | "Scale up first" - single-node capacity has a ceiling |
| parallel_replicas | Heavy queries accelerated by 1.3-1.8× (light queries became slower) | "Use parallel_replicas before sharding" - valid for heavy queries; must be enabled selectively |
| Read scaling | Concurrency from 1→2 scaled linearly by 2.0× | "Adding replicas = linear read scaling" |
| QPS (by query weight) | Full-table scan ~48 → filtered aggregation ~370 → point lookup ~2,780 → empty query ~5,860 | QPS is a function of query complexity, not a fixed cluster value |
| Read throughput ceiling | Under a heavy scan workload, saturation at ~4 concurrent queries due to single-node CPU; peak scanning at ~5 billion rows/s | "Read throughput = number of replicas × single-node concurrency" |
| HA | No interruption on single-replica failure; QPS fell 50%; self-healed in ~65s | "Multi-primary peers; when one fails, the others continue as normal" |

### Alignment with the Design Positioning

This round of performance testing in a real AWS environment validated the core propositions of this design (see [`docs/community-corroboration.en.md`](./community-corroboration.en.md)): **scale up a single shard vertically, use local NVMe to maximize the IO ceiling, add replicas for linear read scaling, and use parallel_replicas for heavy queries to postpone sharding**. All figures are measured results, and **unfavorable results, such as `parallel_replicas` slowing down light queries, are also recorded faithfully** rather than selectively omitted.

### Potential Follow-up Work (Not Covered in This Round)

- **Write / merge throughput testing** (using the NYC Taxi dataset) - this round focused on reads and did not stress writes.
- **Retesting with 3 replicas** - the current environment has 2 replicas (limited by i8g capacity); after adding the third replica, the linear QPS extrapolation can be validated.
- **Timing node-level failure recovery** - this round tested at the Pod level (the data volume survived); full rebuild time after complete node and local-disk loss was not measured.

---

## Appendix: Raw Data

- Per-query latency for 43 queries: [`docs/perf-results/clickbench-43queries.csv`](./perf-results/clickbench-43queries.csv)
- Test scripts and topology: see the repository's `manifests/` and `scripts/`
