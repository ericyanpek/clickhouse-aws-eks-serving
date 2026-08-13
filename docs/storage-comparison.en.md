# Parallel ClickHouse Local-NVMe and EBS Comparison

[中文](./storage-comparison.md) · **English**

> Status: the infrastructure and test automation are implemented. A 1×2 EBS-only run completed on 2026-08-11; see [`storage-comparison-results.en.md`](./storage-comparison-results.en.md). Test resources are destroyed after preserving the results; this document continues to describe the repeatable parallel design.
>
> Goal: retain the existing `i8g.4xlarge + local NVMe` cluster unchanged and add an independent `r8g.4xlarge + gp3` cluster on the same EKS, Operator, Keeper, monitoring stack, and benchmark node. Compare them with the same ClickHouse version, topology, resource limits, dataset, and queries.

## 1. Parallel Architecture

```text
                         same EKS / Operator / Keeper
                                      |
                 +--------------------+--------------------+
                 |                                         |
       baseline CHI: ch                         comparison CHI: ch-ebs
       cluster: main                            cluster: mainebs
       3 x i8g.4xlarge                          3 x r8g.4xlarge
       16 vCPU / 128 GiB                        16 vCPU / 128 GiB
       local NVMe 3.75 TB                       gp3 3400 GiB
       local-storage                            clickhouse-ebs-gp3
                 |                                         |
                 +------------- same benchmark client -----+
```

`enable_ebs_comparison=false` is the default, so existing node pools, CHI, PVCs, services, and deployment behavior remain unchanged. Explicitly enabling it only adds:

- 3 `r8g.4xlarge` nodes, one per AZ.
- 3 3400 GiB gp3 data volumes.
- The `clickhouse-ebs-gp3` StorageClass.
- An independent `ch-ebs` CHI, Service, PVCs, and PDB.

The EBS comparison cluster shares the existing Keeper and system components but does not share ClickHouse data volumes or query Pods.

Each gp3 volume remains an AZ-scoped resource. After a node failure, the EKS node group can add a node in the same AZ and the Pod can reattach its existing EBS volume without reloading the full replica. If the entire AZ is unavailable, the volume cannot be attached across AZs; the other two replicas serve traffic while the replica is rebuilt from another replica, backup, or the lakehouse.

## 2. Instance and EBS Parameters

According to EC2 `DescribeInstanceTypes` in `us-east-1` on 2026-08-11:

| Item | i8g.4xlarge | r8g.4xlarge |
|---|---:|---:|
| vCPU | 16 | 16 |
| Memory | 128 GiB | 128 GiB |
| Local storage | 1 × 3750 GB NVMe | None |
| EBS baseline | 20,000 IOPS / 625 MB/s | 20,000 IOPS / 625 MB/s |
| EBS maximum | 40,000 IOPS / 1,250 MB/s | 40,000 IOPS / 1,250 MB/s |

`r8g.4xlarge` keeps the CPU architecture, vCPU count, and memory equal without paying for unused instance-store capacity.

The first comparison provisions gp3 at `40,000 IOPS / 1,250 MiB/s`, the R8g.4xlarge EBS channel ceiling. This measures the architectural difference between high-performance EBS and local NVMe instead of an artificial bottleneck caused by the gp3 defaults of `3,000 IOPS / 125 MiB/s`.

A second run should lower EBS to `20,000 IOPS / 625 MiB/s` to determine whether baseline bandwidth already satisfies the workload and to quantify the value of additional provisioned performance.

Note that 40,000 / 1,250 is the peak instance EBS channel, not the sustained R8g.4xlarge baseline. Provisioning the volume at that level adds performance headroom but cannot bypass the instance limit. Long-running tests must monitor EC2 `EBSIOBalance%`, `EBSByteBalance%`, and EBS volume queue depth. If the workload must continuously exceed 20,000 IOPS / 625 MiB/s, test a larger instance with a higher EBS baseline instead of increasing gp3 settings on the same R8g.4xlarge.

## 3. Test Method

The test script reuses this project's established method:

1. ClickBench `hits`: 99,997,497 rows and 105 columns, approximately 13.45 GiB compressed. The script explicitly pins column types, partition key, sorting key, and sampling key instead of inferring the schema at runtime.
2. The historical ClickBench 43-query suite from 2026-07-05, retaining the best of 3 runs. The download is verified against SHA-256 `a7d6673357348ee9680443216b6f26f30d1dce9f313b419d38502417b2c2a219`.
3. `warm`: preserve the existing best-of-3 warm-run basis.
4. `direct_io`: set `min_bytes_to_use_direct_io=1` so page cache does not hide the storage difference.
5. QPS: point lookup, filtered aggregation, and empty query at concurrency 8 for 12 seconds; full-table aggregation at concurrency 1, 2, 4, 8, and 16.
6. Require ClickHouse `25.3.14.14`, two replicas for the historical comparison, and the dedicated `c7g.2xlarge` benchmark node. Record active parts/marks so physical-layout differences are not misreported as storage differences.
7. Record data-load and replica catch-up time plus node, PVC, PV, and StorageClass metadata.

Output is written to `results/storage-comparison/<UTC timestamp>/`. Primary files:

- `clickbench.csv`
- `load-seconds.csv` (separate timings for the initial insert and all three replicas becoming current)
- `disks-local_nvme.tsv` / `disks-ebs_gp3.tsv`
- `qps-*.txt`
- `qps-queries.sql`
- `clickbench-queries.sql` / `clickbench-queries.sha256`
- `benchmark-client.tsv`
- `parts-local_nvme.tsv` / `parts-ebs_gp3.tsv`
- `nodes.txt`
- `pods-pvcs.txt`
- `pvs.txt`
- `storage-classes.yaml`

## 4. Deployment and Test

Deploy and verify the existing local-NVMe baseline before adding the EBS comparison:

```bash
CLICKHOUSE_ADMIN_PASSWORD='...' ./scripts/deploy.sh

CLICKHOUSE_ADMIN_PASSWORD='...' \
  CONFIRM_CREATE_EBS_COMPARISON=yes \
  ./scripts/deploy-ebs-comparison.sh

CLICKHOUSE_ADMIN_PASSWORD='...' \
  ./scripts/run-storage-comparison.sh
```

Set `AUTO_APPROVE=true` only for automation or after reviewing the Terraform plan. The EBS add-on creates continuously billable EC2 and EBS resources.

While the EBS cluster exists, keep the following in `terraform/terraform.tfvars`:

```hcl
enable_ebs_comparison = true
```

Otherwise, a later `terraform apply` without a command-line override removes the EBS node pools and StorageClass.

To reuse the historical 1x2 NVMe measurements from 2026-07-05 without creating new i8g nodes, set the following in `terraform/terraform.tfvars`:

```hcl
enable_local_nvme      = false
enable_ebs_comparison  = true
ebs_comparison_zones   = ["us-east-1a", "us-east-1b"]
public_access_cidrs    = ["YOUR_CURRENT_PUBLIC_IP/32"]
```

Then deploy and test only the 1x2 EBS profile:

```bash
CLICKHOUSE_ADMIN_PASSWORD='...' \
  CONFIRM_CREATE_EBS_ONLY_TEST=yes \
  ./scripts/deploy-ebs-only.sh

COMPARE_LOCAL=false \
  CLICKHOUSE_ADMIN_PASSWORD='...' \
  ./scripts/run-storage-comparison.sh
```

This mode still creates a new EKS cluster plus Keeper, system, and benchmark nodes, but it does not create i8g instances, a local-NVMe CHI, or local-disk data. Destroy the entire temporary environment after testing:

```bash
CONFIRM_DELETE_EBS_ONLY_TEST=yes \
  ./scripts/teardown-ebs-only.sh
```

Remove only the EBS add-on after testing:

```bash
CONFIRM_DELETE_EBS_COMPARISON=yes \
  ./scripts/teardown-ebs-comparison.sh
```

The existing local-NVMe `ch` cluster is not deleted by this cleanup script.

## 5. Interpreting Results

Compare:

| Dimension | Primary metrics |
|---|---|
| Warm queries | 43-query best-of-3, p50, p90, and total time |
| Storage-sensitive queries | Direct-I/O versus warm latency |
| Concurrent reads | Three query classes at c=8; full-table query scaling at c=1/2/4/8/16 |
| Ingestion | S3 load time and replication catch-up time |
| Background pressure | Merge queue, replication queue, and CPU iowait |
| Recovery | Ready time and replication queue after Pod restart and node replacement |
| Cost | EC2, EBS capacity, provisioned IOPS/throughput, and operational cost |

ClickBench is only approximately 13.45 GiB, smaller than the Pod's 110 GiB memory allocation, so warm results may mostly measure CPU and page cache. Storage selection must also consider direct I/O, merge/insert pressure with a larger dataset, and node-level recovery.

The 2026-08-11 run found the warm 43-query results effectively on par. Filtered aggregation is not directly comparable because the historical and current active-parts layouts differed. See [`storage-comparison-results.en.md`](./storage-comparison-results.en.md) for the full limitations and CloudWatch evidence.

### 5.1 Node-Recovery Comparison

Restarting a Pod on its original node does not demonstrate EBS failover. Run node recovery as a separate test:

1. Keep a low-concurrency query running and record error rate and available replicas.
2. Record the target Pod, PVC, node, and AZ; confirm the EBS node group has `max_size=2` and R8g quota in that AZ.
3. Perform a controlled `kubectl drain` on one EBS node. The PDB retains the other two replicas, and Cluster Autoscaler should add a node in the same AZ so the original PVC can reattach.
4. Record three intervals: eviction to Pod Ready, eviction to successful ClickHouse queries, and eviction to an empty replication queue.
5. The local-NVMe control remains tied to its original node by local-PV node affinity. After permanent node loss, `recover-local-replica.sh` must remove the failed local PV and reload the replica from a healthy peer.

A controlled drain is an optimistic recovery test. A real EC2 host loss also includes node-loss detection and forced EBS detach time. Simulating that requires separate approval to terminate an instance and confirmation that a second replica will not be affected.

## 6. Decision Guidance

- Prefer EBS if tuned gp3 meets latency and merge SLAs because it provides shorter, more automated node recovery.
- Choose local NVMe only when the EBS channel remains saturated, merge backlog grows, or cold scans are materially slower.
- Do not choose local storage from average warm-query latency alone if direct-I/O, ingestion, and recovery results do not justify it.
- EBS improves same-AZ reattachment after a node failure; it does not make an EBS volume portable across AZs. Three replicas still provide cross-AZ availability.
- Neither storage option changes the project premise: the lakehouse is the sole SoT and ClickHouse is a rebuildable OLAP acceleration layer.
