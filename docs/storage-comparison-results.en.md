# ClickHouse Local-NVMe and EBS Performance Results

[中文](./storage-comparison-results.md) · **English**

> Test date: 2026-08-11  
> Conclusion: on the 13.48 GiB ClickBench dataset, which fits entirely inside the 110 GiB memory allocation, the 43 warm queries on `r8g.4xlarge + gp3` were effectively on par with the historical `i8g.4xlarge + local NVMe` result. This does not prove equivalence for cold data or sustained merge workloads.

## 1. Comparison Contract

Only EBS was rerun; NVMe uses the historical measurements from 2026-07-05. The EBS run locked:

| Item | Historical NVMe baseline | This EBS run |
|---|---|---|
| ClickHouse | 25.3.14.14 | 25.3.14.14 |
| Topology | 1 shard × 2 replicas | 1 shard × 2 replicas |
| Data nodes | 2 × i8g.4xlarge | 2 × r8g.4xlarge |
| Pod resources | 14 vCPU / 110 GiB | 14 vCPU / 110 GiB |
| Benchmark host | Dedicated c7g.2xlarge | Dedicated c7g.2xlarge |
| Data | 99,997,497 rows | 99,997,497 rows |
| Table | 105-column `ReplicatedMergeTree` | Same 105 columns, partition key, sorting key, and sampling key |
| Queries | ClickBench 43 queries | Same historical file, SHA-256 `a7d6673357348ee9680443216b6f26f30d1dce9f313b419d38502417b2c2a219` |

Each EBS replica used a 3400 GiB gp3 volume provisioned at 40,000 IOPS / 1,250 MiB/s. All performance traffic originated from the benchmark Pod inside EKS and targeted the ClusterIP. The local Mac only orchestrated the test through SSM and the Kubernetes API.

### 1.1 Evidence Boundary

The historical NVMe report retained the ClickHouse version, a table-key excerpt, the 43-query results, and QPS logs, but not the full runtime `SHOW CREATE TABLE` or an active-parts inventory. The old Keeper table path no longer exists. This run recovered the 43 SQL statements from the ClickBench commit current on 2026-07-05 and pinned the official DDL's 105 ClickHouse 25.3 column types plus the project's key definitions in the script.

The run therefore implements a reproducible logical contract, but it cannot retrospectively hash-prove all 105 columns of the destroyed NVMe table. The filtered aggregation also exposed a physical parts-layout difference, described in Section 3.

## 2. 43 Warm Queries

Each query ran three times in one connection, retaining the best result:

| Metric | NVMe | EBS | EBS relative to NVMe |
|---|---:|---:|---:|
| Total | 18.756s | 18.334s | -2.25% |
| Average | 0.436s | 0.426s | -2.29% |
| p50 | 0.175s | 0.172s | -1.71% |
| p90 | 1.268s | 1.250s | -1.42% |
| Slowest Q29 | 5.211s | 5.081s | -2.49% |

The `-2.25%` result must not be interpreted as EBS outperforming NVMe. The dataset is smaller than memory, so warm best-of-3 primarily measures Graviton4 CPU, ClickHouse execution, and page cache. The difference is normal run-to-run variation.

Raw results:

- NVMe: [`perf-results/clickbench-43queries.csv`](./perf-results/clickbench-43queries.csv)
- EBS warm + direct I/O: [`perf-results/ebs-gp3-clickbench-43queries.csv`](./perf-results/ebs-gp3-clickbench-43queries.csv)

## 3. QPS

Three query classes used concurrency 8 for 12 seconds; the full-table aggregation also ran at concurrency 1/2/4/8/16:

| Query class | NVMe QPS | EBS QPS | Assessment |
|---|---:|---:|---|
| Point lookup `WHERE CounterID=62` | 2774.391 | 2416.823 | EBS -12.9%, comparable |
| Filtered aggregation | 369.720 | 1032.252 | **Not comparable** |
| `SELECT 1` | 5851.224 | 5268.330 | EBS -10.0%, mainly request path/CPU |
| Full-table `GROUP BY RegionID` | 47.900 | 50.651 | EBS +5.7%, effectively on par |

Both sides used the same filtered aggregation:

```sql
SELECT RegionID, count()
FROM hits
WHERE CounterID = 62
GROUP BY RegionID
ORDER BY count() DESC
LIMIT 10;
```

However, the NVMe log reports approximately 8,530,531 rows read per query, while EBS read only 743,073. Each EBS replica had already merged down to two active parts. The historical NVMe run has no parts inventory. Primary-key mark over-read differed by 11.5×, so `369.720` versus `1032.252` is not a storage-media comparison and must not drive selection.

Every full scan read all 99,997,497 rows, so it is unaffected by that difference:

| Concurrency | NVMe QPS | EBS QPS |
|---:|---:|---:|
| 1 | ~22.5 | 22.195 |
| 2 | ~44.8 | 44.258 |
| 4 | ~50.5 | 45.673 |
| 8 | ~52.0 | 50.651 |
| 16 | ~52.0 | 48.199 |

See [`perf-results/ebs-gp3-qps-summary.csv`](./perf-results/ebs-gp3-qps-summary.csv).

## 4. EBS Direct I/O

`min_bytes_to_use_direct_io=1` is an EBS-only diagnostic. There is no historical NVMe run with the same setting, so no cross-media ratio is valid:

| Metric | EBS warm | EBS direct I/O |
|---|---:|---:|
| 43-query total | 18.334s | 39.568s |
| Average | 0.426s | 0.920s |
| p50 | 0.172s | 0.427s |
| p90 | 1.250s | 2.202s |
| Q24 | 1.307s | 6.755s |
| Q29 | 5.081s | 6.116s |

This proves that bypassing page cache materially affects some queries, but it does not establish how much faster NVMe would be under the same setting.

## 5. EBS Observations

CloudWatch one-minute metrics during the test window:

| Metric | us-east-1b volume | us-east-1a volume |
|---|---:|---:|
| Peak read throughput | ~332 MiB/s | ~224 MiB/s |
| Peak read IOPS | ~3,880 | ~2,270 |
| Peak average VolumeQueueLength | 3.24 | 1.92 |
| Minimum instance EBSByteBalance% | 99% | 99% |
| Minimum instance EBSIOBalance% | 99% | 99% |

The run remained far below the provisioned 40,000 IOPS / 1,250 MiB/s per volume. For this 13.48 GiB read test, 20,000 IOPS / 625 MiB/s would likely have been sufficient. Any reduction still needs validation with target ingestion, merge, and recovery workloads.

## 6. HA Test Status and TODO

This run **did not execute an EBS HA test**, so this report provides no evidence for service continuity, EBS reattachment time, or recovery RTO. The next run must first restore the Operator, Keeper, the 1 shard × 2 replicas EBS CHI, and the same 99,997,497-row dataset.

The first test must be a **Pod deletion test identical to the historical NVMe method**. A node-termination test must not replace it:

- Target the ClusterIP from the dedicated `c7g.2xlarge` benchmark node.
- Fix the query to `SELECT RegionID, count() FROM hits GROUP BY RegionID ORDER BY count() DESC LIMIT 10`.
- Run `clickhouse-benchmark` continuously with concurrency 4 and `--continue_on_errors`, then delete one ClickHouse replica Pod.
- Record the two-replica baseline QPS, one-replica QPS, query errors, service continuity, Pod deletion-to-Ready time, Pod deletion-to-first-successful-query time, and replication-queue drain time.
- Record the Pod node, PVC, PV, and `VolumeAttachment` before and after deletion to verify whether the replacement Pod reuses the same EBS volume.

The historical NVMe reference is approximately 47–48 QPS with two replicas, 25–26 QPS with one replica, one transient error, and approximately 65 seconds to recover. That result was also a Pod deletion test with the node retained. **EBS detach/attach after node loss is a second, separate scenario** and should independently measure same-AZ scheduling, volume reattachment, and ClickHouse recovery.

Closeout state on 2026-08-11: EKS and all nine EC2 nodes remain running; no EC2 stop/terminate or Terraform infrastructure destroy operation was executed. However, the ClickHouse namespace, Keeper, EBS CHI, PVCs, and test data had already been removed during the interrupted cleanup, and the Operator reinstall did not complete because the SSM/Kubernetes API path timed out. The next run must begin by restoring the Operator and workloads and must not assume that the cluster still contains ClickHouse data.

## 7. Decision

1. For a ClickBench dataset that fits in memory, R8g + high-performance gp3 and i8g + NVMe are effectively on par for warm queries. NVMe showed no decision-grade advantage.
2. EBS's primary architectural value remains same-AZ volume reattachment after node failure. This run did not execute a node-failure recovery test, so it provides no measured RTO.
3. Direct I/O shows that storage-sensitive queries can still be affected by EBS. Demonstrating an NVMe advantage requires a larger dataset and sustained INSERT/merge workload with identical parts layouts at the same point in time.
4. Exclude filtered-aggregation QPS from selection unless both sides first use the same parts-normalization policy and record `system.parts`.
5. The project premise remains unchanged: the lakehouse owns the sole authoritative data truth, and ClickHouse is a rebuildable OLAP acceleration layer. EBS and NVMe are alternative performance, cost, and recovery profiles.
