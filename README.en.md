# ClickHouse on Amazon EKS OLAP Acceleration Layer

[中文](./README.md) · **English**

> **Architecture prerequisite:** the data lakehouse is the sole authoritative Source of Truth (SoT). It retains complete history and supports replay. ClickHouse stores only derived, rebuildable MergeTree data and serves as a low-latency OLAP / BI acceleration layer; it is neither the primary data store nor the sole source of truth.
>
> This repository deploys ClickHouse on EKS only. It does not create the upstream lakehouse or implement Kafka/Flink ingestion jobs. Before adopting this design, you must already have a replayable lakehouse and a batch or streaming synchronization path. The S3 bucket created by this repository is only for ClickHouse backup/DR; it is **not the lakehouse SoT**.

## 1. Positioning and Value

This project provides reviewable, executable Terraform + Kubernetes IaC that deploys the following into your AWS account:

- ClickHouse: **one or more independent clusters on demand**, defaulting to a single 1 shard × 3 replica cluster, each replica on a dedicated cross-AZ `r8g.4xlarge` node with its own gp3 data volume.
- ClickHouse Keeper: a **dedicated** 3-node cross-AZ quorum **per cluster**, with persistent EBS storage.
- Altinity ClickHouse Operator `0.27.1`.
- Prometheus, Grafana, daily S3 backup, and IRSA permissions.
- Scripts for NVMe initialization, deployment, validation, lost-node recovery, and ordered teardown.
- Per-cluster teardown (`teardown.sh --cluster <key>`), so adding or removing one cluster leaves the others untouched.

The set of clusters is defined by the Terraform `clickhouse_clusters` map, whose key is the cluster identifier. Adding a cluster means adding a key: because node groups are addressed by string key rather than list index, adding or removing one cluster does not touch another cluster's resources. Each cluster independently sets its topology, storage medium, instance size, and ClickHouse version.

The data volume medium is the primary tradeoff. After measurement the **default is EBS gp3** (clear operational recovery advantages, negligible performance cost in mainstream scenarios), with local NVMe equally available as a performance profile for storage-bound workloads. Rationale and costs are in [4.3](#43-data-volume-selection-ebs-gp3-versus-local-nvme).

Its value is not to replace ClickHouse Cloud. It is a self-managed reference implementation for cases where:

- Data must run entirely inside your AWS account and VPC.
- You need control over ClickHouse topology, scheduling, settings, storage, and upgrade timing.
- The lakehouse already owns the sole data truth and needs a rebuildable hot-query acceleration layer.
- You need consistent IaC for a POC, cost assessment, performance validation, and compliance review.

For a ClickHouse Cloud-to-OSS migration POC, this repository addresses EKS deployment, storage, HA, backup, and operations. It does **not** include Kafka/Flink dual-write, historical backfill, result comparison, or traffic cutover logic; those belong to the upstream data pipeline.

## 2. Current Architecture

```text
Kafka / Flink / Batch
         |
         | authoritative write
         v
Data Lakehouse on S3 (Iceberg / Delta / Hudi / Parquet)
Sole SoT, complete history, replayable
         |
         | incremental load / replay
         v
+------------------------- Amazon EKS, 3 AZ -------------------------+
| ClickHouse 1 shard x 3 replicas                                   |
|   i8g.4xlarge + local NVMe, one Pod per node                      |
|                                                                    |
| ClickHouse Keeper 3 nodes + EBS                                   |
| Altinity Operator + local-static-provisioner                      |
| Prometheus + Grafana                                               |
+------------------------------+-------------------------------------+
                               |
                               | daily backup via IRSA
                               v
                    S3 backup bucket (not the SoT)
```

Key properties:

| Dimension | Current implementation |
|---|---|
| Data role | Lakehouse is the sole SoT; ClickHouse is an eventually consistent, rebuildable OLAP acceleration layer |
| ClickHouse topology | 1 shard × 3 replicas, fixed at 3 data nodes |
| Data storage | Default is approximately 3.4 TiB local NVMe per replica, `ReplicatedMergeTree`; measurements recommend gp3 instead, see [4.3](#43-data-volume-selection-ebs-gp3-versus-local-nvme) |
| Coordination | 3-node Keeper on EBS `gp3-encrypted` |
| Service exposure | `ClusterIP`, not publicly exposed by default |
| Disaster recovery | ClickHouse replicas + daily S3 backup; the upstream lakehouse remains the authoritative full-recovery source |
| Images | ClickHouse / Keeper `25.3` LTS |

## 3. Data Flow and Kafka/Flink Boundary

Recommended data ownership:

1. Kafka/Flink or batch processing first guarantees that events reach the lakehouse, which retains complete, authoritative, replayable data.
2. The same job or a separate derivation job writes ClickHouse while maintaining watermarks, idempotency keys, schema mappings, and failure replay.
3. During a POC, fan out the same normalized stream to ClickHouse Cloud and the OSS cluster deployed by this project.
4. Validate both targets with fixed time windows, row and aggregate checks, query-result diffs, and latency metrics.
5. After cutover, keep the lakehouse as the sole SoT so either ClickHouse cluster can be rematerialized.

Possible ingestion patterns include a Flink ClickHouse connector, Kafka engine + Materialized View, batch `INSERT SELECT` from Iceberg/Parquet, or externally orchestrated incremental backfill. The right choice depends on delivery semantics and throughput. This repository neither implements nor promises exactly-once delivery.

## 4. Key Design Tradeoffs

### 4.1 EKS vs. EC2

- EKS fits organizations that already have a Kubernetes platform team and need GitOps, unified observability, and scheduling controls.
- EC2 is usually more direct when operating only one ClickHouse cluster and minimizing control-plane complexity.
- This repository chooses EKS to reuse Altinity Operator and platform capabilities. It does not claim EKS is always better than EC2.

### 4.2 One Shard, Three Replicas

The default strategy is to scale up before sharding. Adding a shard does not automatically redistribute historical data. Introduce real sharding only when single-node capacity or single-query compute becomes the bottleneck, and design an explicit resharding process. Three replicas provide cross-AZ availability and read scaling; they do not change the lakehouse's SoT role.

### 4.3 Data Volume Selection: EBS gp3 versus Local NVMe

> **The repository now defaults to EBS gp3.** The default value of `clickhouse_clusters` is a single cluster with `storage_profile = "ebs"`, and `./scripts/deploy.sh` renders the CHI accordingly with a per-cluster gp3 volume. Local NVMe remains a first-class option: set that cluster's `storage_profile` to `"local-nvme"`. The rationale and costs are below.

#### 4.3.1 Measured Results

The [2026-08-12 same-run selection experiment](./docs/storage-selection-report.en.md) deployed both media in parallel on one EKS cluster, at the same version, topology, resource envelope, and load generator:

| Scenario | Result | Winner |
|---|---|---|
| Warm ClickBench (working set fits in memory) | +2.8% to +3.9% | On par |
| Direct I/O (page cache forcibly bypassed) | EBS 66-78% slower, up to 3x on individual queries | **Local** |
| `OPTIMIZE FINAL` merge convergence | EBS 48% slower (4,916s vs 3,321s) | **Local** |
| Permanent node loss recovery | EBS reattaches the volume in 111s with zero rebuild; local must reload about 130 GiB | **EBS** |
| Monthly cost (1x2, excluding shared costs) | Local $2,004.29; EBS $2,180.14 | Local, by 8.77% |

The merge row deserves its mechanism spelled out: both media moved **nearly the same number of bytes** (about 1.0 TiB per node), and the entire difference is sustained throughput (217 vs 328 MiB/s). During the merge EBS sat at 102% device utilization with p95 at 1,130-1,193 MiB/s against a 1,250 MiB/s provisioned ceiling, while local NVMe peaked at 2,630-2,815 MiB/s and still stayed under 89% utilization. **That is a difference in capability headroom -- EBS's ceiling is purchased, instance storage's is given by the hardware.**

#### 4.3.2 Why EBS Is the Default Recommendation

Under this project's premise (the lakehouse is the SoT and ClickHouse is a rebuildable acceleration layer), EBS wins on operations rather than performance:

- **Node replacement needs no data reload.** Measured in the [2026-08-13 HA drill](./docs/ha-drill-report.en.md): stopping a data node let the original volume reattach to a same-AZ replacement within 111 seconds with **zero data rebuild** and only 3 seconds of service interruption. The same failure on local storage requires [`recover-local-replica.sh`](./scripts/recover-local-replica.sh) to reload roughly 130 GiB from a healthy replica or the lakehouse, making RTO a function of data volume.
- **Routine operations cause no interruption.** Pod deletion and `kubectl drain` both produced zero failed queries in the drill, which makes node rolling upgrades, AMI rotation, and autoscaler scale-down low-risk.
- **Capacity is decoupled from the instance.** Volume size is no longer bounded by the instance-store capacity of a given instance type, can be grown independently, and IOPS/throughput can be changed online without rebuilding the node.
- **The performance cost is negligible in mainstream scenarios.** Warm queries are on par; EBS only falls behind materially on storage-bound work.

The price is **8.77% more per month** and **maintenance windows sized at roughly 1.5x** (merges are 48% slower). For a rebuildable acceleration layer, trading 8.77% to eliminate "reload 130 GiB whenever a node dies" is usually worth it.

#### 4.3.3 When Local NVMe Is Still the Right Choice

Local storage's performance advantage becomes decision-grade if any of the following holds:

- The query working set **substantially exceeds memory**, with frequent page-cache-bypassing scans (EBS is 66-78% slower on direct I/O).
- There is a **strict direct-I/O tail-latency** SLA.
- Background merges must finish inside a **fixed nightly window**, where a 48% difference would overrun it.
- Throughput must be **sustained beyond the instance EBS channel**. Note that `r8g.4xlarge` is a burstable size: 1,250 MB/s is available only 30 minutes per 24 hours before falling back to a 625 MB/s baseline. If sustained load genuinely needs high throughput, the correct move is `r8g.8xlarge`, where baseline equals maximum, not more volume provisioning.

Choosing local storage means accepting that data is permanently lost when a node terminates, that a local PV does not automatically move, and that recovery is manually triggered. **This tradeoff is valid only because ClickHouse data is rebuildable from the lakehouse**; if ClickHouse is the only data source, this repository's recovery model does not apply.

#### 4.3.4 How to Switch

To reproduce the comparison against your own data and queries, declare two clusters in `clickhouse_clusters` at once -- one with `storage_profile = "ebs"` and one with `local-nvme` -- which share the same EKS, monitoring, and load-generation node. Historical material also includes the [2026-08-11 EBS-only measurements](./docs/storage-comparison-results.en.md).

Switching to EBS requires changing three things together: the CHI's `storageClassName` (`local-storage` to a gp3 class), the instance type (`i8g` to `r8g`), and the node group's subnet binding -- **a gp3 volume is AZ-scoped, so each node group must be pinned to a single subnet**. Otherwise a replacement node may land in a different AZ, fail to attach the original volume, and the recovery advantage in 4.3.2 does not hold.

### 4.4 S3 Backup

`clickhouse-backup` stores ClickHouse recovery points to reduce disaster-recovery time. The backup bucket does not replace the lakehouse. Teardown retains it by default and removes it from Terraform state.

## 5. Relationship to Other Options

- **ClickHouse Cloud on AWS:** vendor-managed, operationally lighter, and more elastic. It is usually the first choice when self-management is not a hard requirement.
- **Altinity Terraform EKS Blueprint:** this project reuses its VPC/EKS/node-group and operator infrastructure, but replaces its encapsulated cluster layer with owned CHI/CHK manifests.
- **AWS data-on-eks:** a broader data-platform reference stack; this project focuses on a fixed 1×3 topology, dedicated nodes, a selectable storage medium, and fewer dependencies.

One way this project differentiates from the above is that storage-medium selection is treated as a **reproducible measurement** rather than a judgment call: both media are deployed in parallel on one cluster, producing five classes of evidence -- query, merge, device-level I/O, recovery RTO, and cost -- with explicit notes on which conclusions do not hold.

See the [documentation index](./docs/README.en.md) for the status of design evidence, performance results, and historical records.

## 6. Prerequisites and Cost

Required:

- Terraform `>= 1.5`
- AWS CLI with working credentials
- `kubectl` and Helm 3
- Permissions for EKS, VPC/EC2, IAM, and S3
- Quota and capacity for at least 3 `i8g.4xlarge` instances in the target region; if switching to gp3 per [4.3](#43-data-volume-selection-ebs-gp3-versus-local-nvme), 3 `r8g.4xlarge` instances plus the corresponding gp3 capacity and IOPS quota instead
- An existing lakehouse, schema management, and replayable ingestion path

> **Capacity risk (encountered in practice):** during the 2026-08-12 experiment neither `us-east-1b` nor `us-east-1c` could supply the required `i8g.4xlarge` capacity, which forced both replicas into a single AZ and invalidated that run's cross-AZ and HA conclusions. Newer storage-optimized families like `i8g` can be supply-constrained in some AZs. Before planning a cross-AZ topology, confirm real capacity with Service Quotas and an actual `run-instances` probe rather than assuming quota equals availability.

This deployment is expensive while continuously running. It includes 3 data nodes, 3 Keeper nodes, 3 system nodes, 1 benchmark node, NAT Gateway, and the EKS control plane. With gp3 you must also budget per-replica volume capacity plus any IOPS and throughput above the free tier. Pricing varies by region and date. Verify with AWS Pricing Calculator and Service Quotas before apply; historical estimates in this repository are not quotes.

## 7. Configuration

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

At minimum, review:

```hcl
region              = "us-east-1"
availability_zones  = ["us-east-1a", "us-east-1b", "us-east-1c"]

backup_bucket_name  = ""
public_access_cidrs = ["203.0.113.0/24"]

# The set of clusters. Defaults to a single ebs cluster; add a key to add a cluster.
clickhouse_clusters = {
  ebs = {
    storage_profile = "ebs"
    shards          = 1
    replicas        = 3
  }
  # nvme = {
  #   storage_profile = "local-nvme"
  #   shards          = 1
  #   replicas        = 3
  # }
}
```

`availability_zones` must contain three real, distinct AZs in the same region, and each cluster's `zones` must be a subset of it. The default `public_access_cidrs` exposes the EKS public API and must be restricted for production.

Each cluster's `cpu_request`, `memory_request`, and `data_volume_size_gib` are sized for a 16 vCPU / 128 GiB Graviton instance. Change `instance_type` and you must adjust all three, or pods will fail to schedule because their requests exceed what the node can allocate.

## 8. Deployment

An admin password is mandatory:

```bash
CLICKHOUSE_ADMIN_PASSWORD='replace-with-a-strong-secret' ./scripts/deploy.sh
```

The script validates the password before creating infrastructure, computes its SHA-256 hash, and writes only the hash to a temporary manifest. Terraform requires interactive approval by default. CI must explicitly opt into non-interactive execution:

```bash
CLICKHOUSE_ADMIN_PASSWORD='...' AUTO_APPROVE=true ./scripts/deploy.sh
```

Deployment order:

1. Create the VPC, EKS cluster, node groups, S3 backup bucket, and IRSA.
2. Install the operator, monitoring, and local-static-provisioner.
3. Use a DaemonSet to format and mount instance-store NVMe on ClickHouse nodes.
4. Apply manifests in namespace, backup configuration, Keeper, ClickHouse, and Grafana dashboard order.

Do not directly apply the committed CHI. Its `REPLACE_WITH_ADMIN_SHA256` placeholder must be substituted by the deployment flow.

## 9. Validation and Access

```bash
kubectl -n clickhouse get chi,chk,pods
./scripts/smoke-test.sh
```

The smoke test validates the 1×3 topology, ReplicatedMergeTree writes, cross-replica synchronization, and `system.replicas`.

ClickHouse is available only inside the cluster by default. For temporary access:

```bash
kubectl -n clickhouse port-forward svc/clickhouse-ch 8123:8123
curl -u admin:yourpassword "http://localhost:8123/?query=SELECT+version()"
```

## 10. Monitoring

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
```

Monitor replica delay, replication queues, disk usage, merge backlog, query latency, CPU, memory, and network. The repository's dashboard ConfigMap is a starting point; production use requires validation against actual metric names and appropriate alert thresholds.

## 11. Backup and Recovery

A daily CronJob calls `clickhouse-backup` at `02:00 UTC` and uploads one complete replica of the single shard to a versioned, encrypted, public-access-blocked S3 bucket.

Inspect backups:

```bash
kubectl -n clickhouse get cronjob clickhouse-backup-daily
kubectl -n clickhouse get jobs
cd terraform && terraform output -raw backup_bucket
```

When a local-NVMe node is permanently lost, Kubernetes does not automatically move its PVC to a new node. After confirming that the node will not return and at least one other replica is healthy, run:

```bash
CONFIRM_REPLICA_DATA_LOSS=yes \
  ./scripts/recover-local-replica.sh chi-ch-main-0-1
```

The script refuses to delete a Ready Pod, handles only a `local-storage` PVC, briefly pauses the operator while removing the old Pod/PVC/PV, restores the operator, and waits for the replacement replica. After the Pod is Ready, verify that `system.replicas` queues have drained.

This reload flow is not needed with EBS data volumes. In the [2026-08-13 drill](./docs/ha-drill-report.en.md), stopping a data node let the original volume reattach to a **same-AZ** replacement node within 111 seconds, with zero data rebuild and 3 seconds of service interruption. This depends on each node group being pinned to a single subnet: a gp3 volume is AZ-scoped, so if a node group spanned several subnets the replacement node could land in another AZ and fail to attach. The result comes from a controlled instance stop and does not cover AZ-level failure or loss of the volume itself; if the volume is lost, the recovery path is the same as local storage.

**PDB caveat:** do not hand-write a PodDisruptionBudget for ClickHouse pods. The Altinity operator already creates one per cluster (`maxUnavailable: 1`), and adding another that selects the same pods makes them **permanently unevictable** -- the eviction API refuses any pod covered by more than one PDB, which blocks `kubectl drain`, node rolling upgrades, and autoscaler scale-down indefinitely. This defect was found and fixed during the 2026-08-13 drill.

If every ClickHouse replica is lost, rebuild by partition from the upstream lakehouse first. The ClickHouse S3 backup is an auxiliary recovery point for reducing RTO, not the authoritative data source.

## 12. Teardown

```bash
./scripts/teardown.sh
```

The script removes in-cluster resources before destroying EKS/VPC. It retains the S3 backup bucket together with versioning, encryption, and public-access-block settings, and removes those resources from Terraform state. It prints the exact bucket name. Delete all object versions and the bucket manually only after confirming that the backups are no longer needed.

## 13. Scope Boundaries and Documentation Rules

Current non-goals:

- It does not deploy a lakehouse, Glue Catalog, Kafka/MSK, or Flink.
- It does not implement Cloud/OSS dual-write, historical backfill, CDC, deduplication, or result comparison.
- It does not provide a public load balancer, TLS, authentication proxy, or multi-tenant isolation.
- It does not provide automatic sharding, automatic local-PV failure recovery, or elastic scale-out.
- It never defines ClickHouse or the backup bucket as the sole SoT.

`README.md` and `README.en.md` are the synchronized Chinese and English canonical entry points. Their section numbering and technical facts must remain aligned. Research, test reports, and historical implementation plans under `docs/` are supporting artifacts; see [docs/README.en.md](./docs/README.en.md) for authority and version status.
