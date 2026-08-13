# ClickHouse on Amazon EKS OLAP Acceleration Layer

[中文](./README.md) · **English**

> **Architecture prerequisite:** the data lakehouse is the sole authoritative Source of Truth (SoT). It retains complete history and supports replay. ClickHouse stores only derived, rebuildable MergeTree data and serves as a low-latency OLAP / BI acceleration layer; it is neither the primary data store nor the sole source of truth.
>
> This repository deploys ClickHouse on EKS only. It does not create the upstream lakehouse or implement Kafka/Flink ingestion jobs. Before adopting this design, you must already have a replayable lakehouse and a batch or streaming synchronization path. The S3 bucket created by this repository is only for ClickHouse backup/DR; it is **not the lakehouse SoT**.

## 1. Positioning and Value

This project provides reviewable, executable Terraform + Kubernetes IaC that deploys the following into your AWS account:

- ClickHouse: **1 shard × 3 replicas**, each on a dedicated cross-AZ `i8g.4xlarge` node with local NVMe.
- ClickHouse Keeper: a 3-node cross-AZ quorum with persistent EBS storage.
- Altinity ClickHouse Operator `0.27.1`.
- Prometheus, Grafana, daily S3 backup, and IRSA permissions.
- Scripts for NVMe initialization, deployment, validation, lost-node recovery, and ordered teardown.

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
| Data storage | Approximately 3.4 TiB local NVMe per replica, `ReplicatedMergeTree` |
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

### 4.3 Local NVMe

Local NVMe provides high IO, but its data is permanently lost when a node terminates, and a local PV does not automatically move. This tradeoff is valid only because ClickHouse data is rebuildable from the lakehouse. If ClickHouse is the only data source, use a more durable storage design and reassess this repository's recovery model.

The repository also provides a disabled-by-default [parallel R8g + high-performance gp3 comparison](./docs/storage-comparison.en.md) that does not replace the existing cluster, plus an EBS-only mode that reuses historical NVMe results without creating i8g nodes. The [2026-08-11 EBS measurements](./docs/storage-comparison-results.en.md) found the small warm ClickBench workload effectively on par with NVMe and explicitly record the direct-I/O and active-parts comparability limits.

The [2026-08-12 same-run selection experiment](./docs/storage-selection-report.en.md) deployed both media in parallel on one cluster, giving a fuller boundary:

| Scenario | Result |
|---|---|
| Warm ClickBench (working set fits in memory) | On par, +2.8% to +3.9% |
| Direct I/O (page cache bypassed) | EBS +66% to +78% slower, up to 3x on individual queries |
| `OPTIMIZE FINAL` merge convergence | **EBS +48% slower**; cumulative device I/O was nearly identical (about 1.0 TiB per node), so the entire difference is sustained throughput (217 vs 328 MiB/s) |
| Monthly cost (1x2, excluding shared costs) | Local $2,004.29; EBS at 20k IOPS / 1,250 MiB/s $2,180.14, an 8.77% premium |

The conclusion is **EBS gp3 as the default production profile, with local NVMe as an explicit performance profile**. Local storage becomes decision-grade only when the workload has frequent page-cache-bypassing scans, strict direct-I/O tail-latency requirements, or background merges that must finish inside a fixed nightly window (EBS needs roughly 1.5x the maintenance window).

The [2026-08-13 HA and recovery drill](./docs/ha-drill-report.en.md) validated the EBS profile's recovery behavior: pod deletion and graceful eviction caused **zero interruption**, and controlled permanent node loss cost **3 seconds** of service interruption with the pod back in 111 seconds and **zero data rebuild** -- the original volume reattached to a same-AZ replacement node. The local-NVMe profile's HA was not tested and must not be inferred from this.

### 4.4 S3 Backup

`clickhouse-backup` stores ClickHouse recovery points to reduce disaster-recovery time. The backup bucket does not replace the lakehouse. Teardown retains it by default and removes it from Terraform state.

## 5. Relationship to Other Options

- **ClickHouse Cloud on AWS:** vendor-managed, operationally lighter, and more elastic. It is usually the first choice when self-management is not a hard requirement.
- **Altinity Terraform EKS Blueprint:** this project reuses its VPC/EKS/node-group and operator infrastructure, but replaces its encapsulated cluster layer with owned CHI/CHK manifests.
- **AWS data-on-eks:** a broader data-platform reference stack; this project focuses on a fixed 1×3 topology, dedicated nodes, local NVMe, and fewer dependencies.

See the [documentation index](./docs/README.en.md) for the status of design evidence, performance results, and historical records.

## 6. Prerequisites and Cost

Required:

- Terraform `>= 1.5`
- AWS CLI with working credentials
- `kubectl` and Helm 3
- Permissions for EKS, VPC/EC2, IAM, and S3
- Quota and capacity for at least 3 `i8g.4xlarge` instances in the target region
- An existing lakehouse, schema management, and replayable ingestion path

This deployment is expensive while continuously running. It includes 3 i8g data nodes, 3 Keeper nodes, 3 system nodes, 1 benchmark node, NAT Gateway, and the EKS control plane. Pricing varies by region and date. Verify with AWS Pricing Calculator and Service Quotas before apply; historical estimates in this repository are not quotes.

## 7. Configuration

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

At minimum, review:

```hcl
region             = "us-east-1"
availability_zones = ["us-east-1b", "us-east-1c", "us-east-1d"]
clickhouse_zones    = ["us-east-1b", "us-east-1c", "us-east-1d"]

backup_bucket_name = ""
public_access_cidrs = ["203.0.113.0/24"]
```

`availability_zones` and `clickhouse_zones` must contain three real, distinct AZs in the same region. The default `public_access_cidrs` exposes the EKS public API and must be restricted for production.

Resources are sized for `i8g.4xlarge`. When changing instance type, also update CPU, memory, and PVC capacity in the [ClickHouse manifest](./manifests/20-clickhouse-chi.yaml).

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
