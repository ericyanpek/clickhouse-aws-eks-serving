# ClickHouse Local-NVMe vs EBS Storage-Selection Experiment Report

[中文](./storage-selection-report.md) · **English**

> Status: **the 2026-08-12 single run completed query, concurrency, ingestion, CloudWatch, merge timing, and merge-window device-level I/O evidence; repeat runs, sustained load, and HA remain pending (PARTIAL)**
> Project boundary: the upstream lakehouse retains the sole authoritative source of truth (SoT); ClickHouse is a rebuildable OLAP acceleration layer. This report selects the acceleration layer's storage, performance, recovery, and cost model without changing data authority.
> Reporting rule: only same-run results that satisfy the hardware, topology, data, query, and observability contract in this document may drive the final selection.
> Current scope: this run first establishes storage-performance evidence. HA, PDB normalization, and recovery drills are separate follow-up TODOs. Query, ingestion, or merge performance must not be used to infer HA capability or recovery RTO.
> Actual-topology disclosure: on 2026-08-12, insufficient `i8g.4xlarge` capacity in `us-east-1b` and `us-east-1c` required the local-NVMe performance phase to use two nodes in `us-east-1a`; the logical topology remained 1 shard × 2 replicas. EBS used `us-east-1a` + `us-east-1b`. Local reads, queries, and device I/O remain usable for storage-performance comparison, but replicated writes, cross-AZ latency, and HA are not Apple-to-Apple.

## 1. AWS SA Decision Framework

From an AWS Solutions Architect perspective, storage selection cannot rely on single-query latency alone. The final recommendation evaluates six dimensions:

| Dimension | Question to answer | Decision evidence |
|---|---|---|
| Business and SLA | What are the target query latency, concurrency, ingestion rate, RTO, and acceptable error window? | p50/p95/p99, QPS, ingest rate, recovery time, error count |
| Performance ceiling | Is the bottleneck CPU, memory, block storage, or the instance EBS channel? | CPU, iowait, disk throughput/IOPS/latency, EBS balance, queue depth |
| Resilience and recovery | How do service and replicas recover from Pod, node, and AZ failures? | Segmented RTO for Pod deletion, node loss, EBS reattachment, and local-disk reload |
| Data durability | Does permanent node loss cause authoritative data loss? | Lakehouse replay, healthy-replica fetch, and backup recovery paths |
| Operational complexity | Which option is easier to automate, scale, upgrade, and repair? | Manual steps, runbooks, alarms, and recovery-drill success rate |
| Cost efficiency | What is paid per unit of throughput, scanned data, and availability? | Monthly cost, cost per billion rows ingested, per TiB scanned, and per million queries |

Decision order:

1. Eliminate any option that fails a hard SLA, capacity, or recovery objective.
2. Compare unit-of-work cost and operational risk only among options that meet the SLA.
3. If the performance difference is within repeat-run variance, prefer EBS for simpler recovery and lower risk.
4. Select local storage only when the EBS channel is proven to be a sustained bottleneck and local NVMe benefits justify reload and operational costs.

## 2. Official Dataset and Deterministic 10× Scale

### 2.1 Official ClickBench Baseline

The **primary dataset is the official ClickBench 100M**, using the ClickHouse-published `hits`-compatible data and official query suite:

- Official repository: https://github.com/ClickHouse/ClickBench
- Official 100M Parquet: https://datasets.clickhouse.com/hits_compatible/hits.parquet
- Official results: https://benchmark.clickhouse.com/
- Official hardware results: https://benchmark.clickhouse.com/hardware/
- Official ClickHouse DDL: https://github.com/ClickHouse/ClickBench/blob/main/clickhouse/create.sql
- Official 43-query suite: https://github.com/ClickHouse/ClickBench/blob/main/clickhouse/queries.sql
- Official `clickhouse-benchmark` documentation: https://clickhouse.com/docs/operations/utilities/clickhouse-benchmark

The baseline `hits` table contains 99,997,497 rows and 105 columns. The query file is pinned to the project-validated commit and verified by SHA-256 so upstream changes cannot break reproducibility.

### 2.2 Project-Generated Deterministic 10× Data

The 10× phase is **project-derived stress data, not a separate official 10× ClickBench dataset published by ClickHouse**:

- Load the same official Parquet data deterministically 10 times for a target total of 999,974,970 rows.
- For each copy, add fixed offsets only to `WatchID`, `UserID`, and `FUniqID` to avoid fully duplicated identifiers.
- Dates, event attributes, and all remaining columns retain the official data distribution. NVMe and EBS use the same script, offsets, and batch order.
- This method creates an out-of-memory scan, ingestion, parts, and merge workload. It does not represent ten independent weeks of production traffic and cannot predict compression or cardinality changes under organic data growth.

The final report must present official 1× and derived 10× results separately and must not aggregate them together.

### 2.3 Public Download and Storage-Timing Boundary

The current load path uses `url(...)` to run the NVMe and EBS loads sequentially from the public ClickHouse dataset. End-to-end elapsed time includes:

- Public-network transfer, remote-service variance, and intermediary cache-hit differences.
- Parquet decompression, decoding, type conversion, and ClickHouse INSERT CPU.
- Local data-volume writes, WAL/part creation, replication transfer, and replica catch-up.

Therefore, `insert_seconds` and `replicas_ready_seconds` from sequential public loads are **end-to-end ingestion results** and cannot be interpreted directly as pure NVMe or EBS storage performance. The final report must separate:

1. Download/decoding path: source bytes, download time, decode CPU time, execution order, and retries.
2. ClickHouse storage path: block-device write MiB/s, IOPS, await, utilization, part/merge throughput, and replica catch-up.
3. Storage-isolated test: stage the same immutable data behind equivalent in-region sources, alternate profile order, and time the write phase separately. If this is not completed, the field must read `NOT ISOLATED`, and the report must not claim that one medium has faster "pure-storage ingestion."

## 3. Hardware and Topology Contract

| Item | Local NVMe | EBS gp3 |
|---|---|---|
| Data nodes | 2 × `i8g.4xlarge` | 2 × `r8g.4xlarge` |
| CPU / memory | 16 vCPU / 128 GiB | 16 vCPU / 128 GiB |
| ClickHouse Pod | request 14 vCPU / 110 GiB; memory limit 110 GiB | Identical |
| Target topology contract | 1 shard × 2 replicas across 2 AZs | Identical |
| Actual topology for the 2026-08-12 performance phase | 1 shard × 2 replicas; both nodes in `us-east-1a` | 1 shard × 2 replicas; `us-east-1a` + `us-east-1b` |
| ClickHouse | `25.3.14.14` | Identical |
| Data volume | `local-storage`, 3400 Gi PVC | gp3, 3400 Gi PVC |
| First EBS tier | Not applicable | 40,000 IOPS / 1,250 MiB/s |
| Instance EBS channel | Not on the ClickHouse data path | Baseline 5,000 Mbps (625 MB/s = 596.05 MiB/s) / 20k IOPS; maximum 10,000 Mbps (1,250 MB/s = 1,192.09 MiB/s) / 40k IOPS |
| Query endpoint | Dedicated ClusterIP | Dedicated ClusterIP |
| Load generator | Dedicated `c7g.2xlarge` benchmark node | Same node and client image |
| Operator / Keeper | Same EKS, Operator, and Keeper | Same shared infrastructure |

The test contract also requires:

- Identical table DDL, sorting key, partition key, sampling key, user settings, and replica count.
- Record the AMI, kernel, filesystem, mount options, ClickHouse image digest, node allocatable resources, and DaemonSet overhead before testing.
- Invalidate or explicitly qualify any run with CPU throttling, memory pressure, a network bottleneck, abnormal replication lag, or mismatched background activity.
- Normalize both PDBs before HA testing. The current test manifests use local `minAvailable: 1` and EBS `minAvailable: 2`; without correction, a controlled drain is not an Apple-to-Apple test.
- Validate production capacity and HA separately for the final 1×3 topology; 1×2 is the storage-media A/B contract.
- Unit convention: the AWS instance EBS channel is rated in decimal MB/s while gp3 provisioned throughput is rated in MiB/s, so the two must not be mixed directly. This report converts everything to MiB/s before comparing.
- **Burst limit (decision-relevant):** the `r8g.4xlarge` EBS channel has a baseline below its maximum, making this a burstable size — it sustains the 1,192.09 MiB/s / 40k IOPS maximum for at most 30 minutes per 24 hours before reverting to the 596.05 MiB/s / 20k IOPS baseline. `r8g.8xlarge` is the smallest size in this family whose baseline equals its maximum. Any workload running beyond 30 minutes (this run's merge ran 55 and 82 minutes on the two profiles) must be planned against the 596.05 MiB/s baseline rather than the maximum.

### 3.1 Actual Topology and Comparability Boundary on 2026-08-12

On 2026-08-12, `i8g.4xlarge` capacity was unavailable in `us-east-1b` and `us-east-1c`. To preserve the infrastructure already provisioned and continue the performance phase, local NVMe used two `i8g.4xlarge` nodes in `us-east-1a`; EBS continued to use two `r8g.4xlarge` nodes split across `us-east-1a` and `us-east-1b`. Both ClickHouse deployments retained the same logical topology of 1 shard × 2 replicas.

This actual topology supports comparison only within the following boundary:

- Local reads, ClickBench queries, and device I/O attributable to the ClickHouse data volume may be compared after the remaining test-contract checks pass.
- The single-replica local write path may be used as supporting evidence, but end-to-end write results that include replica completion are also affected by the same-AZ versus cross-AZ network-path difference.
- Replicated writes, replica catch-up, and cross-AZ latency are not Apple-to-Apple and must not be used to claim an NVMe or EBS storage-write advantage.
- HA and recovery under Pod, node, or AZ failure are not Apple-to-Apple and remain TODO. Before execution, the test requires symmetric AZ placement plus normalized PDBs, fault methods, and load.

## 4. Experimental Controls and Execution Rules

1. Alternate NVMe-first and EBS-first ordering across repeat runs to reduce time and cache bias.
2. Run every valid phase at least three times; report the median, worst run, and coefficient of variation.
3. Before each phase, validate row count, `SHOW CREATE TABLE`, query SHA-256, active parts, marks, replication queues, and replica health.
4. Report warm, direct-I/O, and cold-cache results separately. Warm results must not represent storage performance.
5. Load identical batches with background merges paused, then start `OPTIMIZE ... FINAL` from equivalent parts layouts.
6. Generate all performance traffic from the dedicated in-EKS benchmark node through ClusterIP. The local workstation only orchestrates the run.
7. Preserve all raw logs, system-table snapshots, node/PV/PVC/VolumeAttachment state, and UTC timestamps.
8. Do not change instance type, ClickHouse settings, EBS parameters, queries, or data layout within a phase.
9. Record public-load execution order and report it separately from storage-isolated timing. Do not calculate a storage-media delta from two sequential end-to-end download results.
10. Accept HA and recovery evidence only from a separate fault experiment after PDB normalization; do not extrapolate it from performance phases.

## 5. Test Phases

| Phase | Workload | Purpose | Primary output |
|---|---|---|---|
| P0 Preflight | Idle and infrastructure snapshot | Prove both profiles satisfy the contract | Configuration, versions, nodes, parts, disk baseline |
| P1 Official 1× | 43 queries, warm + direct I/O | Retain historical compatibility and isolate cache effects | Per-query latency, total, p50/p95/p99 |
| P2 1× concurrency | Point, filtered aggregate, and full aggregate at c=1/2/4/8/16 | Find CPU, service, and storage saturation | QPS, tail latency, errors, scaling efficiency |
| P3a Deterministic 10× end-to-end ingest | Sequentially load 10 fixed batches through public `url(...)` | Measure the combined download, decode, write, and replication path | End-to-end rows/s, batch time, replication lag, execution order |
| P3b Storage-isolated ingest | Stage identical data behind equivalent sources and alternate order | Remove download/decode contamination and compare the ClickHouse storage path | Device write MiB/s/IOPS/await, parts, and replica catch-up |
| P4 Deterministic 10× queries | 43 queries and concurrency ramp | Exceed memory and expose storage differences | Warm/direct-I/O latency, QPS, scan throughput |
| P5 Merge contention | c=4 full scan during `OPTIMIZE FINAL` | Model query and maintenance contention | Merge time, QPS loss, tail latency, iowait |
| P6 EBS tier sweep | 40k/1250, 20k/1250, 20k/1000, 20k/625, 3k/125 | Separate IOPS and throughput effects before finding the gp3 cost/performance knee | SLA, volume/instance limit utilization, cost delta |
| P7 Pod recovery (follow-up TODO) | After PDB normalization, delete one replica Pod during continuous queries | Apple-to-Apple Pod self-healing comparison | Errors, continuity, Ready/queryable time |
| P8 Node failure (follow-up TODO) | After PDB normalization, controlled loss of one data node | Compare EBS reattachment with NVMe reload | Segmented RTO, degraded QPS, recovery traffic |
| P9 Sustained mixed load | Target ingest + queries + merges for at least 2 hours | Expose queue and credit behavior hidden by short tests | SLA compliance, backlog, balance, thermal stability |

P7/P8 are outside the current performance conclusion. Before execution, normalize the PDBs, fault-injection method, and continuous-query load. P8 must also preserve the distinct recovery models: EBS reattaches the original volume to a replacement node in the same AZ; NVMe rebuilds from a healthy replica and, when required, reloads from the lakehouse. These are not identical actions, but both are timed from "node unavailable" to "full redundancy restored."

## 6. Metrics and Observability

| Category | Required metrics |
|---|---|
| Queries | p50/p95/p99, maximum latency, QPS, timeouts, errors, read_rows, read_bytes |
| Download/decoding | Source bytes, download time, decode CPU, execution order, cache state, and retries |
| End-to-end ingestion | rows/s, batch insert time, replication-queue drain time, part creation rate |
| Storage-isolated writes | Block-device write MiB/s, IOPS, await, utilization, and part/merge throughput |
| Merges | Merge wall time, bytes/s, parts before/after, query QPS and tail-latency degradation |
| Host | CPU, steal, load, memory, page cache, major faults, iowait |
| Block device | Read/write MiB/s, IOPS, average request size, await, utilization, queue depth |
| EBS | VolumeRead/WriteBytes, VolumeRead/WriteOps, VolumeQueueLength, EBSByteBalance%, EBSIOBalance% |
| ClickHouse | `system.query_log`, `system.parts`, `system.merges`, `system.replicas`, asynchronous metrics |
| Recovery | Detection, scheduling, attach/disk creation, Pod Ready, first query, replica catch-up, full redundancy |
| Quality | Configuration hash, query hash, row count, parts/marks, anomalies, and invalidation reason per run |

Results must include absolute values and relative differences, with confidence intervals or at least repeat-run dispersion. A standalone latency number without read/write volume and resource-utilization evidence cannot drive selection.

## 7. Cost Model

The prices below came from the AWS Price List API on 2026-08-12 for `us-east-1`, Linux On-Demand, using 730 hours per month. They include only ClickHouse data-node compute and data volumes. Common root volumes, EKS, Keeper, monitoring, backup, and transfer are excluded, so these figures compare incremental cost rather than a complete bill.

| Cost item | Local NVMe | EBS gp3 |
|---|---:|---:|
| EC2 hourly price per node | $1.37280 | $0.94256 |
| Data node count | 2 | 2 |
| Monthly data-node compute | $2,004.29 | $1,376.14 |
| Monthly data-volume capacity | Included instance store | $544.00 |
| Monthly additional gp3 IOPS | Not applicable | $370.00 |
| Monthly additional gp3 throughput | Not applicable | $90.00 |
| Two-node comparison total/month | **$2,004.29** | **$2,380.14** |
| EBS relative to local | Baseline | **+$375.85 / +18.75%** |
| Linear target 1×3 estimate/month | $3,006.43 | $3,570.21 |
| Backup / S3 / data transfer | Excluded | Excluded |
| Shared EKS, Keeper, monitoring | Excluded | Excluded |
| Estimated operations hours/month | `PENDING` | `PENDING` |

Required calculations:

```text
Monthly infrastructure cost = EC2 + EBS capacity + EBS IOPS + EBS throughput + backup/transfer + shared allocation
Cost per billion rows ingested = test-window cost / rows ingested × 1,000,000,000
Cost per TiB scanned = test-window cost / TiB scanned
Cost per million successful queries = test-window cost / successful queries × 1,000,000
Failure-recovery risk cost = assumed failure frequency × degraded duration × business-impact rate
```

The current per-volume gp3 cost is $272/month for 3400 GiB, $185/month for the additional 37k IOPS, and $45/month for the additional 1125 MiB/s. Reducing only IOPS to 20k while retaining 1250 MiB/s would lower the two-node comparison total to approximately $2,180.14/month, about 8.77% above local NVMe, and better matches this run's observations than cutting throughput immediately. One-year and three-year commitment sensitivity remains required; discounts must not hide provisioned EBS costs or NVMe recovery operations.

## 8. Decision Boundaries

### 8.1 Prefer EBS

EBS is the default recommendation when all of the following hold:

- It meets query, ingestion, merge, and recovery SLAs under the target sustained workload.
- The volume and instance EBS channel are not continuously saturated, or reasonable gp3/instance tuning resolves the issue.
- Its unit-of-work cost premium over NVMe stays within the business threshold: `PENDING`.
- Reattaching the original volume materially shortens time to full redundancy and reduces manual steps after node loss.

### 8.2 Select Local NVMe

Recommend local NVMe only when the evidence chain is complete:

- The 10× and sustained phases prove the EBS storage path, rather than CPU, memory, parts layout, or the client, is the bottleneck.
- A reasonably tuned EBS profile still misses the SLA, or meeting the SLA with EBS is materially more expensive.
- NVMe benefits persist across repeat runs and exceed predefined materiality thresholds: latency/QPS `PENDING`; unit cost `PENDING`.
- The business accepts the replica-rebuild window after node loss, and healthy-replica, lakehouse-replay, and backup runbooks have been exercised.

### 8.3 Conclusions Not Supported

- Equivalent official 1× warm ClickBench results do not prove storage equivalence.
- One faster direct-I/O run does not independently prove production benefit.
- Remaining below 40k IOPS / 1250 MiB/s does not prove default gp3 is sufficient.
- Faster end-to-end ingestion during sequential public loading does not prove that the corresponding storage medium writes faster.
- A Pod restarting on its original node does not represent node-failure recovery.
- Better query, ingestion, or merge performance does not imply better HA or a shorter recovery RTO.
- Rebuilding local storage from a replica does not replace the lakehouse SoT or backup strategy.
- Higher concurrent-query QPS during the first 300s of a merge does not imply the merge will finish sooner — in this run EBS posted slightly better QPS over the first 300s yet finished 48.0% later overall.
- `system.part_log.read_bytes` reports uncompressed logical bytes and must not be treated as device bytes when computing storage bandwidth or judging whether provisioned throughput is saturated.

## 9. Limitations and Validity Threats

1. `i8g.4xlarge` and `r8g.4xlarge` have equal CPU/memory dimensions but are not identical laboratory hardware and do not have identical pricing.
2. The official 1× data fits within 110 GiB of memory, so warm queries mainly measure CPU, execution, and page cache.
3. Deterministic 10× data repeats the source distribution and expands only row count and selected identifier spaces; it does not model organic business growth.
4. Sequential public downloads introduce network, cache, and remote-service variance. Without P3b, there is no valid pure-storage ingestion-latency conclusion.
5. `OPTIMIZE FINAL` is a repeatable merge-stress mechanism, not a substitute for every production background-merge pattern.
6. The 1×2 A/B topology is not the project's target 1×3 topology. Production cost, degraded capacity, and fault tolerance require extrapolation followed by validation.
7. In the 2026-08-12 performance phase, both local-NVMe nodes were in `us-east-1a`, while the EBS nodes were split across `us-east-1a` and `us-east-1b`. Local reads/queries and device I/O are comparable, but replicated writes, cross-AZ latency, and HA are not Apple-to-Apple.
8. EBS is AZ-scoped. Same-AZ reattachment is not cross-AZ volume mobility.
9. NVMe rebuild depends on healthy replicas, network capacity, and lakehouse availability; results vary with data size and parts layout.
10. HA/PDB normalization and recovery experiments are incomplete, so performance results are not availability evidence.
11. Shared Keeper, EKS networking, and the benchmark node can become common bottlenecks and must be excluded through observation.
12. AWS prices, instance capabilities, and service quotas change. Record the lookup date, region, and account quotas in the final report.
13. The merge-retry orchestration died partway through the EBS profile (the operator's SSM tunnel dropped, killing the runner and benchmark client processes with it), so the runner never wrote the EBS row of `merge-final.csv` and never wrote `parts-after-merge-ebs_gp3.tsv`. The ClickHouse server was unaffected and completed the merge normally; both artifacts were recaptured afterward from server state. **The differing capture times must be stated honestly:** the local parts snapshot was written by the runner at merge completion, while the EBS one was captured manually on 2026-08-13 after the fact using the same query. The timing comparisons in Sections 10.2 and 10.4 therefore use the `part_log` basis on both sides to avoid this asymmetry.
14. Timing bases must not be mixed: the local `optimize_seconds` = 3,346s is the runner's wall clock (it wrapped `SYSTEM START MERGES` plus `OPTIMIZE FINAL`), whereas the `part_log` basis gives 3,321s, a 25s difference. No runner wall-clock value exists for EBS. The published comparison therefore uses only the like-for-like `part_log` basis (4,916 versus 3,321, +48.0%); comparing 4,916 against 3,346 yields a spurious +46.9% across mismatched bases and must not be published.
15. On the local profile, `OPTIMIZE ... ON CLUSTER ... FINAL` returned while replica 0 had 1 active part and replica 1 still had 13, whereas both EBS replicas had converged to 1. The local span is therefore biased toward the initiating replica rather than representing both-replicas-converged time, so the true like-for-like gap is somewhat wider than 48.0%. A valid future comparison must require both profiles to converge to 1/1.
16. `system.part_log` contains many `error=234` (`NO_REPLICA_HAS_PART`) rows: 1,473 of 1,978 on EBS and 1,377 of 1,889 on local. These record replica-queue fetch attempts that lost the race to a local merge. They appear symmetrically on both profiles and are benign rather than failed merges, but they inflate event counts, so every `part_log` aggregate must first filter on `error=0`.

## 10. 2026-08-12 Single-Run Results (PARTIAL)

> Raw run directory: `results/storage-selection/20260812T052520Z`; the merge-contention retry and device-level I/O evidence live in `results/storage-selection-merge-retry/20260812T075959Z`. See [`perf-results/storage-selection-20260812-summary.csv`](./perf-results/storage-selection-20260812-summary.csv) for the committable language-neutral summary. This is one run; repeat runs, sustained load, and HA are incomplete. Every assessment below remains subject to the actual-AZ boundary in Section 3.1, and the merge timing is additionally subject to items 13-16 in Section 9.

### 10.1 Validity Checks

| Check | Local NVMe | EBS gp3 | Status |
|---|---|---|---|
| Configuration contract matched | 16 vCPU / 128 GiB; Pod 14 vCPU / 110 GiB; CH 25.3.14.14 | Identical | PASS: instance family and storage intentionally differ |
| 1× / 10× row counts matched | 99,997,497 / 999,974,970 | Identical | PASS; old `dataset-*.tsv` mislabeled part counts as rows, and the script is fixed |
| DDL and query hashes matched | 105 columns and keys validated | Identical | PASS; 43-query file SHA-256 pinned |
| Parts / marks comparable | 1× 289 parts / 12,662 marks; 10× 2,885 / 126,524 | 1× 289 / 12,668; 10× 2,880 / 126,520 | PASS: differences are small |
| No client or shared-component bottleneck | Not fully proven | Not fully proven | QUALIFIED: connection QPS differs and one-run full-scan concurrency is noisy |
| Download/decoding isolated from storage timing | No | No | `NOT ISOLATED`; report end-to-end observations only |
| Cross-profile AZ placement matched | No: `us-east-1a` × 2 | No: `us-east-1a` + `us-east-1b` | FAIL: replicated writes, cross-AZ latency, and HA are not comparable |
| Merge starting parts matched | 2,883 / 2,883 | 2,887 / 2,887 | PASS: 0.14% difference, equivalent starting point |
| Both replicas converged to 1 part after merge | No: 1 / 13 | Yes: 1 / 1 | QUALIFIED: the local span is biased toward the initiating replica, so the like-for-like gap is somewhat wider than 48.0% (Section 9, item 15) |
| Merge timing basis identical on both sides | `part_log` 3,321s (runner wall clock separately 3,346s) | `part_log` 4,916s (no runner wall clock) | PASS: the `part_log` basis is used throughout; cross-basis comparison excluded (Section 9, item 14) |

### 10.2 Performance Results

| Phase / metric | Local NVMe | EBS gp3 | Delta | Assessment |
|---|---:|---:|---:|---|
| 1× warm 43-query total | 19.357s | 19.900s | +2.81% | Effectively on par; working set fits in memory |
| 1× direct-I/O 43-query total | 22.826s | 40.699s | +78.30% | EBS is materially slower when page cache is bypassed |
| 1× direct-I/O p95 | 1.759s | 2.646s | +50.43% | Lower NVMe tail latency; repeat validation required |
| 10× warm 43-query total | 263.391s | 273.694s | +3.91% | On par to mild degradation |
| 10× direct-I/O 43-query total | 282.840s | 470.944s | +66.51% | Clear NVMe advantage for storage-sensitive work |
| 10× direct-I/O p95 | 32.437s | 39.905s | +23.02% | Higher EBS tail latency |
| 10× end-to-end ingest rows/s (includes public download/decode) | 3,366,919 | 3,662,912 | EBS +8.79% | `NOT ISOLATED`; do not attribute to storage |
| 10× storage-isolated write MiB/s | `PENDING` | `PENDING` | `PENDING` | P3b incomplete |
| 10× full-scan QPS (c1 / c8) | 1.862 / 4.250 | 1.803 / 4.169 | -3.17% / -1.91% | c1/c8 effectively on par; c2/c4 are non-monotonic and one run is insufficient |
| Merge span (first to last successful `part_log` merge) | 3,321s | 4,916s | EBS +48.0% | Like-for-like primary result; both sides derived from `part_log`, see Section 10.4 |
| Summed merge duration (`part_log`) | 15,898s | 21,294s | EBS +33.9% | Independent second measure, immune to idle gaps inside the span |
| Successful merges / output volume | 512 / 539.42 GiB | 505 / 526.24 GiB | -1.4% / -2.4% | Equivalent work, which makes the two timing deltas above comparable |
| Query p99 during merge (first 300s window) | 2.279s | 2.237s | -1.84% | Covers only the early merge phase and does not predict completion time, see Section 10.4 |
| Sustained-load SLA compliance | `PENDING` | `PENDING` | `PENDING` | `PENDING` |

### 10.3 Storage Results

| Metric | Local NVMe | EBS gp3 | Assessment |
|---|---:|---:|---|
| One-minute average / peak read+write throughput | Complete NVMe device series unavailable | Per volume 106.20 / 1,040.68 and 129.11 / 954.34 MiB/s; combined-window average 235.32 and aggregate peak 1,374.76 | Per-volume peaks reached 83.3% / 76.3% of the 1,250 MiB/s **volume** provisioned ceiling and 87.3% / 80.1% of the 1,192.09 MiB/s **instance** channel maximum; they are 1.75x / 1.60x the 596.05 MiB/s sustainable instance baseline and therefore depend on the 30-minute burst allowance. The two-volume aggregate is indicative only — the volumes sit on different instances and must never be compared against any single-instance limit |
| One-minute average / peak IOPS | Complete NVMe device series unavailable | Per volume 873.13 / 14,992.98 and 1,030.16 / 9,700.52; combined-window average 1,903.30 and aggregate peak 18,754.35 | 40k IOPS has substantial headroom; reduce IOPS first |
| Average / peak queue length | Complete NVMe device series unavailable | Per volume 1.114 / 11.729 and 1.324 / 9.161; summed 2.438 / 14.802 | Phase-specific queuing occurred, without evidence of a sustained high queue |
| EBS exceeded / stalled checks | Not applicable | All three metrics returned zero datapoints | No trigger value was observed; missing datapoints are not explicit zeroes |

### 10.4 Merge-Window Device-Level I/O (First Like-for-Like Comparison)

The source is block-device counters collected by a DaemonSet (~10s sampling, 512-byte sectors; field layout defined in `manifests/80-storage-metrics-collector.yaml`), raw file `results/storage-selection-merge-retry/20260812T075959Z/disk-counters-all.tsv`. Local NVMe is instance store and has no CloudWatch equivalent, so this is the project's **first device-level apple-to-apple evidence across both profiles**. Windows are bounded by the first and last successful `part_log` merge (`error=0` only): local 08:11:36 → 09:06:57 (3,321s), EBS 09:07:46 → 10:29:42 (4,916s).

| Metric (per device, two nodes) | Local NVMe instance store | EBS gp3 | Assessment |
|---|---:|---:|---|
| Window average read | 161.0 / 164.6 MiB/s | 106.7 / 108.6 MiB/s | — |
| Window average write | 163.8 / 166.4 MiB/s | 109.7 / 110.0 MiB/s | — |
| Window average read+write | 324.8 / 331.0 MiB/s | 216.4 / 218.6 MiB/s | EBS averages about 34% lower, matching the +48.0% completion time |
| Per-sample p95 combined | 1,516.8 / 1,650.6 MiB/s | 1,130.1 / 1,193.4 MiB/s | The EBS upper bound is clamped by provisioned throughput |
| Per-sample peak combined | 2,629.6 / 2,815.3 MiB/s | 1,263.7 / 1,296.5 MiB/s | Instance store retains roughly 2x burst headroom that EBS cannot reach |
| Peak device utilization | 86.9% / 88.6% | 102.2% / 102.0% | EBS was saturated during the merge; instance store was not |
| Cumulative window read + write | 1.026 / 1.046 TiB | 1.014 / 1.023 TiB | **Equal work**; both sides moved essentially the same byte volume |
| Average IOPS / bytes per I/O | 2,762 / 2,819; ~120 KiB | 1,415 / 1,428; ~157 KiB | Both below the 256 KiB SSD merge cap |

Three conclusions:

1. **Same work, different time.** Cumulative window I/O is roughly 1.01–1.05 TiB per node on both profiles, so both moved equal byte volumes. The difference is purely rate — EBS averaged 217 MiB/s against local 328 MiB/s, hence +48.0% elapsed time. This points the same direction as the direct-I/O results in Section 10.2 and therefore **corroborates** them rather than conflicting with them.
2. **EBS is saturated while instance store still has headroom.** EBS peaked at 102% utilization with p95 combined throughput of roughly 1,130–1,193 MiB/s, pressed against the 1,250 MiB/s provisioned ceiling. Instance store reached p95 1,517–1,651 and peak 2,630–2,815 MiB/s while staying below 89% utilization. This is a **capability-headroom** difference: the EBS ceiling is purchased, whereas the instance-store ceiling is what the hardware provides.
3. **Throughput-bound, not IOPS-bound.** Dividing average throughput by average IOPS yields about 120 KiB per I/O (local) and 157 KiB (EBS), both under the 256 KiB merge cap. At roughly 157 KiB, saturating the 596.05 MiB/s baseline needs only about 3,900 IOPS, and saturating 1,250 MiB/s needs only about 8,200 — far below the 40,000 provisioned. This supports holding throughput while cutting IOPS.

The EBS window average cross-validates against an independently pulled CloudWatch series (188.2 read + 189.9 write = 378 MiB/s). **The two are not independent evidence of the same thing, however:** the CloudWatch figures were taken over an earlier partial 2,247s window rather than this 4,916s full window, so they differ in both source and length. They indicate a consistent order of magnitude but cannot serve as mutually independent confirmation.

Two earlier conclusions in this report about the merge mechanism require correction; the table above refutes both:

- **Retracted claim 1 (~81 MiB/s, therefore CPU-bound):** derived by dividing final dataset size by wall time (130.245 GiB × 2 replicas / 3,321s ≈ 80.3 MiB/s). The defect is that it ignores cascade write amplification — collapsing 2,887 parts into 1 is not a single pass but several cascading rounds, each re-reading and re-writing the working set.
- **Retracted claim 2 (~911 MiB/s, therefore nearly saturating gp3):** derived as `(2.36 TiB logical read + 539.42 GiB compressed write) / 3,321s ≈ 911.5 MiB/s`. That formula is wrong twice over: it adds uncompressed logical reads to compressed physical writes, then compares the sum against device bandwidth. It overstates the device-measured 324.8–331.0 MiB/s by about 2.8x.
- **Current conclusion:** cascade write amplification is real and worth recording, but it must be labeled as a **logical/uncompressed** measure — `system.part_log.read_bytes` reports uncompressed logical bytes, not device bytes. For the same merges, `read_bytes` = 2.36 TiB, `bytes_uncompressed` = 2.00 TiB, and `size_in_bytes` (compressed) = 539.42 GiB, a compression ratio of 3.79x. The authoritative device figures are those in the table above: local averaged about 328 MiB/s and EBS about 217 MiB/s, with EBS p95 pinned at roughly 1,130–1,193 MiB/s and peak utilization at 102% (saturated), versus instance store reaching p95 1,517–1,651 and peak 2,630–2,815 MiB/s.

**Concurrent-query sampling boundary (important):** the 4-concurrency full-scan window during the merge lasted only 300s, which is about 9.0% of the local merge and about 6.1% of the EBS merge, and it covers non-corresponding phases on the two sides. It is therefore **not "QPS across the merge"**, and the two sides are not strictly comparable. Measured values (zero failed queries on both):

| Metric | Local NVMe | EBS gp3 |
|---|---:|---:|
| Queries completed | 775 | 834 |
| QPS | 2.573 | 2.771 |
| p99 | 2.279s | 2.237s |
| Scan throughput | 9,814.473 MiB/s | 10,570.342 MiB/s |

The counter-intuitive point readers must note: **EBS posted slightly better QPS and tail latency in its first 300s yet finished the merge 48.0% later.** A short concurrent-query sample does not predict merge completion time — sizing a maintenance window from the first few minutes of QPS would materially underestimate how long the EBS profile takes to converge.

### 10.5 HA and Recovery TODO

> **Status: `TODO`. The actual AZ topologies are asymmetric, PDBs are not normalized, and recovery experiments are incomplete; the fields below must not be inferred from performance results.**

| Metric | Local NVMe | EBS gp3 | Assessment |
|---|---:|---:|---|
| PDB and fault method normalized | `TODO` | `TODO` | `TODO` |
| Pod deletion to first successful query | `PENDING` | `PENDING` | `PENDING` |
| Node failure to first successful query | `PENDING` | `PENDING` | `PENDING` |
| Node failure to full redundancy | `PENDING` | `PENDING` | `PENDING` |
| Recovery errors / QPS degradation | `PENDING` | `PENDING` | `PENDING` |

### 10.6 Cost and Final Recommendation

| Metric | Local NVMe | EBS gp3 | Assessment |
|---|---:|---:|---|
| Two-node compute + data volumes/month | $2,004.29 | $2,380.14 | Current high-performance EBS +18.75% |
| Cost per billion rows ingested | Not calculated | Not calculated | Public download/decoding was not isolated, so cost attribution is invalid |
| Cost per TiB scanned | `PENDING` | `PENDING` | `PENDING` |
| Cost per million successful queries | `PENDING` | `PENDING` | `PENDING` |
| Estimated operations hours/month | `PENDING` | `PENDING` | `PENDING` |

**Current recommendation: use EBS gp3 as the default production profile and retain local NVMe as an explicit performance profile.**

**Applicability boundary:** warm-cache and normal-concurrency workloads show only low-single-digit differences, while EBS better fits fixed resident nodes, same-AZ volume reattachment, and reduced reload frequency. If the workload frequently bypasses page cache, requires strict direct-I/O tails, or sustains storage saturation, the measured 23%–78% NVMe advantage may be decision-grade. The new merge evidence tightens this boundary on the operational side: for equal work, EBS merge convergence is 48.0% slower, so **maintenance windows must be sized at roughly 1.5x**. Where background merges must complete inside a fixed overnight window, this may matter more than query latency.

**Accepted risks:** EBS node-failure reattachment RTO, sustained mixed load, and repeat runs remain untested. Local storage still requires accepting rebuild from a healthy replica or the lakehouse after permanent node loss. The current AZ placement is asymmetric, so replicated-write and HA conclusions are invalid. In addition, `r8g.4xlarge` has a burstable EBS channel, yet this run's merge lasted 55 and 82 minutes on the two profiles, far beyond the 30-minute burst allowance. If sustained load requires prolonged high throughput, evaluate `r8g.8xlarge` (baseline equals maximum) instead of relying on burst.

**Next step:** reduce gp3 to 20k IOPS while **retaining 1,250 MiB/s** — observed peaks of roughly 15k IOPS plus 120–157 KiB per I/O show the workload is throughput-bound rather than IOPS-bound. That tier costs about $2,180.14/month for two nodes, an 8.77% premium over local NVMe. **Testing 1,000 and 625 MiB/s is no longer recommended:** merge-window device data shows EBS p95 at roughly 1,130–1,193 MiB/s with 102% peak utilization, meaning more than 5% of the merge window runs above 1,100 MiB/s. Dropping to 1,000 MiB/s would clip merge throughput directly and further extend a convergence time that is already 48% slower. Remaining work: a clean merge rerun with both profiles converging to 1/1, alternating repeat runs, P3b storage-isolated writes, and P7/P8 HA.

**Raw result directories:** `results/storage-selection/20260812T052520Z` (queries, concurrency, ingestion, CloudWatch) and `results/storage-selection-merge-retry/20260812T075959Z` (merge timing and device-level I/O)
