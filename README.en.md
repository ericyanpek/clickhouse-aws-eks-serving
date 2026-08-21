# ClickHouse on Amazon EKS OLAP Acceleration Layer

[中文](./README.md) · **English**

> **Architecture prerequisite:** the data lakehouse is the sole authoritative Source of Truth (SoT). It retains complete history and supports replay. ClickHouse stores only derived, rebuildable MergeTree data and serves as a low-latency OLAP / BI acceleration layer; it is neither the primary data store nor the sole source of truth.
>
> This repository deploys ClickHouse on EKS only. It does not create the upstream lakehouse or implement Kafka/Flink ingestion jobs. Before adopting this design, you must already have a replayable lakehouse and a batch or streaming synchronization path. The S3 bucket created by this repository is only for ClickHouse backup/DR; it is **not the lakehouse SoT**.

## 1. Positioning and Value

This project addresses a specific question: when the lakehouse is already the sole source of truth, how should self-managed ClickHouse be deployed as a rebuildable, low-latency OLAP acceleration layer with a defined operating model?

The design starts by defining ClickHouse's data role, then selects topology and storage accordingly. When ClickHouse is a rebuildable acceleration layer, loss of a local disk does not remove authoritative data. The value of EBS is therefore reduced reload work and faster node replacement, rather than preservation of the only data copy. If ClickHouse is the only copy of the data, this repository's recovery model does not apply.

The repository provides reviewable, executable Terraform + Kubernetes IaC for deploying the following components into your own AWS account:

- ClickHouse: **one or more independent clusters on demand**, defaulting to a single 1 shard × 3 replica cluster, each replica on a dedicated cross-AZ `r8g.4xlarge` node with its own gp3 data volume.
- ClickHouse Keeper: a **dedicated** 3-node cross-AZ quorum **per cluster**, with persistent EBS storage.
- Altinity ClickHouse Operator `0.27.1`.
- Prometheus, Grafana, daily S3 backup, and IRSA permissions.
- Scripts for NVMe initialization, deployment, validation, lost-node recovery, and ordered teardown.
- Per-cluster teardown (`teardown.sh --cluster <key>`), so adding or removing one cluster leaves the others untouched.

The Terraform `clickhouse_clusters` map defines the cluster set, with each map key serving as a cluster identifier. Adding a cluster requires one additional key. Node groups are addressed by string key rather than list index, so adding or removing a cluster does not change the resource addresses of other clusters. Each cluster independently sets its topology, storage medium, instance size, and ClickHouse version.

The data volume medium directly affects recovery procedures, I/O limits, and cost. Based on the measurements, the repository **defaults to EBS gp3**: it simplifies recovery after node failure and performs similarly to local NVMe for warm queries. Local NVMe remains available as a performance profile for storage-bound workloads. Selection criteria are in [4.3](#43-data-volume-selection-ebs-gp3-versus-local-nvme).

This design applies when data must remain in your own VPC, topology and upgrade cadence require direct control, and the lakehouse already holds the sole authoritative data. It does **not replace ClickHouse Cloud**; greater control over infrastructure also brings additional operational responsibility. See [4.0](#40-first-decide-whether-this-approach-fits) for the applicability criteria.

The main tradeoffs are:

| Approach | Primary tradeoff |
|---|---|
| ClickHouse Cloud | Less infrastructure control and a smaller operational scope |
| Self-managed EC2 | Avoids introducing the Kubernetes control plane |
| This repository (EKS + self-managed CHI) | Adds platform complexity in exchange for reviewable IaC |
| Default EBS `1×3` | Adds about 9% to monthly cost; node replacement reattaches the volume instead of reloading data |
| Local NVMe profile | Provides more throughput headroom but requires data reload after node loss |

Storage selection is based on a reproducible experiment. Both media were deployed in parallel on the same EKS cluster, with query, merge, device-level I/O, recovery RTO, and cost recorded separately. The reports also state the limits of each conclusion. Results are in [4.3](#43-data-volume-selection-ebs-gp3-versus-local-nvme) and [11](#11-backup-and-recovery).

As a Cloud-to-OSS migration POC, this repository covers EKS deployment, storage, HA, backup, and operations. It does **not** include Kafka/Flink dual-write, historical backfill, result comparison, or traffic cutover; those belong to the upstream pipeline.

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
|                                                                    |
|  cluster "ebs"  (namespace ck-ebs)      <- default                 |
|    ClickHouse 1 shard x 3 replicas                                 |
|      r8g.4xlarge + gp3 data volume, one Pod per node               |
|    Keeper 3 nodes + gp3            <- dedicated per cluster        |
|                                                                    |
|  cluster "<key>" (namespace ck-<key>)   <- added on demand         |
|    topology / medium / instance / version all set per cluster      |
|    Keeper 3 nodes + gp3            <- not shared with "ebs"        |
|                                                                    |
|  shared: Altinity Operator, Prometheus + Grafana,                  |
|          cluster-autoscaler, local-static-provisioner (if nvme)    |
+------------------------------+-------------------------------------+
                               |
                               | daily backup via IRSA, prefix per cluster
                               v
                    S3 backup bucket (not the SoT)
```

Key properties:

| Dimension | Current implementation |
|---|---|
| Data role | Lakehouse is the sole SoT; ClickHouse is an eventually consistent, rebuildable OLAP acceleration layer |
| Cluster count | One EKS hosts N mutually independent ClickHouse clusters, defined by the `clickhouse_clusters` map |
| Per-cluster topology | 1 shard × 3 replicas by default; `shards` and `replicas` are set independently per cluster |
| Data storage | **EBS gp3 by default** (3,400 GiB / 20,000 IOPS / 1,250 MiB/s per replica); local NVMe is an equally supported performance profile, see [4.3](#43-data-volume-selection-ebs-gp3-versus-local-nvme) |
| Coordination | A **dedicated** 3-node Keeper per cluster, cross-AZ quorum, gp3-backed |
| Isolation granularity | Namespace, CHI, Keeper, node groups, StorageClass, IRSA role, and S3 prefix all derive from the cluster key |
| Service exposure | `ClusterIP`, not publicly exposed by default |
| Disaster recovery | ClickHouse replicas + daily S3 backup; the upstream lakehouse remains the authoritative full-recovery source |
| Images | ClickHouse / Keeper `25.3` LTS, operator `0.27.1` |

## 3. Data Flow and Kafka/Flink Boundary

Recommended data ownership:

1. Kafka/Flink or batch processing first guarantees that events reach the lakehouse, which retains complete, authoritative, replayable data.
2. The same job or a separate derivation job writes ClickHouse while maintaining watermarks, idempotency keys, schema mappings, and failure replay.
3. During a POC, fan out the same normalized stream to ClickHouse Cloud and the OSS cluster deployed by this project.
4. Validate both targets with fixed time windows, row and aggregate checks, query-result diffs, and latency metrics.
5. After cutover, keep the lakehouse as the sole SoT so either ClickHouse cluster can be rematerialized.

Possible ingestion patterns include a Flink ClickHouse connector, Kafka engine + Materialized View, batch `INSERT SELECT` from Iceberg/Parquet, or externally orchestrated incremental backfill. The right choice depends on delivery semantics and throughput. This repository neither implements nor promises exactly-once delivery.

## 4. Key Design Tradeoffs

### 4.0 First Decide Whether This Approach Fits

Before comparing options within a self-managed deployment, determine whether self-management is appropriate. The following six variables directly affect that decision:

| Variable | When it leans this way | Conclusion |
|---|---|---|
| **Data role** | ClickHouse is the only copy, no replayable upstream | **Recovery model does not apply**; every premise assumes rebuildable |
| **Working set** | Hot data fits in memory | Choose EBS gp3; the medium is nearly unobservable |
| **Recovery constraint** | Node replacement must require zero rebuild | EBS *and* single-AZ subnet pinning; neither alone suffices |
| **Single-query compute** | One query must span several machines | Only then shard; otherwise scale up |
| **Organizational capacity** | No platform team | Cloud or EC2 fits better |
| **AZ supply** | Target type unavailable in all 3 AZs | Cross-AZ HA is diagram-only, see [6](#6-prerequisites-and-cost) |

Decision rules, in priority order:

1. **Without an explicit self-management requirement, consider Cloud first.** This design provides greater infrastructure control and adds operational responsibility.
2. **When the lakehouse is already the SoT, ClickHouse can operate as a self-managed acceleration layer.** Authoritative durability remains upstream, allowing ClickHouse to be designed as a rebuildable component.
3. **While one node still holds the data, do not shard.** Adding a shard does not migrate historical data, and re-sharding costs far more than provisioning headroom.
4. **When queries are predominantly warm, choose EBS gp3.** Recovery shifts from reloading to reattaching, at 8.77% more per month.
5. **With several clusters on one EKS, the cluster identity must be a map key** — a list index makes adding or removing one cluster rebuild the others' node groups.

**Conditions that require reassessment:** ClickHouse or the backup bucket is treated as the authoritative data store; or the architecture claims cross-AZ HA while the target instances are available in only one AZ.

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

The merge difference came from sustained throughput rather than data volume. Both media moved **nearly the same number of bytes** (about 1.0 TiB per node), at 217 MiB/s for EBS and 328 MiB/s for local NVMe. During the merge, EBS reached 102% device utilization and a p95 of 1,130-1,193 MiB/s against a provisioned ceiling of 1,250 MiB/s. Local NVMe peaked at 2,630-2,815 MiB/s while remaining below 89% utilization. Under this workload, local NVMe retained more throughput headroom, whereas the EBS limit was constrained by the instance channel and provisioned settings.

#### 4.3.2 Why EBS Is the Default Recommendation

Under this project's premise (the lakehouse is the SoT and ClickHouse is a rebuildable acceleration layer), the primary benefit of EBS is operational recovery rather than query performance:

- **Node replacement needs no data reload.** Measured in the [2026-08-13 HA drill](./docs/ha-drill-report.en.md): stopping a data node let the original volume reattach to a same-AZ replacement within 111 seconds with **zero data rebuild** and only 3 seconds of service interruption. The same failure on local storage requires [`recover-local-replica.sh`](./scripts/recover-local-replica.sh) to reload roughly 130 GiB from a healthy replica or the lakehouse, making RTO a function of data volume.
- **Routine operations cause no interruption.** Pod deletion and `kubectl drain` both produced zero failed queries in the drill, which makes node rolling upgrades, AMI rotation, and autoscaler scale-down low-risk.
- **Capacity is decoupled from the instance.** Volume size is no longer bounded by the instance-store capacity of a given instance type, can be grown independently, and IOPS/throughput can be changed online without rebuilding the node.
- **Warm-query performance is comparable.** The experiment placed both media in the same performance range; the material EBS difference appeared in storage-bound workloads.

The price is **8.77% more per month** and **maintenance windows sized at roughly 1.5x** (merges are 48% slower). Whether this cost is acceptable depends on whether the time and operational cost of reloading about 130 GiB after node failure exceed the incremental EBS expense.

#### 4.3.3 When Local NVMe Is Still the Right Choice

Local NVMe should receive priority evaluation if any of the following conditions holds:

- The query working set **substantially exceeds memory**, with frequent page-cache-bypassing scans (EBS is 66-78% slower on direct I/O).
- There is a **strict direct-I/O tail-latency** SLA.
- Background merges must finish inside a **fixed nightly window**, where a 48% difference would overrun it.
- Throughput must be **sustained beyond the instance EBS channel**. Note that `r8g.4xlarge` is a burstable size: 1,250 MB/s is available only 30 minutes per 24 hours before falling back to a 625 MB/s baseline. If the sustained load requires higher throughput, use `r8g.8xlarge`, where baseline equals maximum, rather than adding more provisioned volume performance.

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

The tradeoff matrix across these four is in [1](#1-positioning-and-value), and whether to self-manage at all is in [4.0](#40-first-decide-whether-this-approach-fits). Design rationale, measurement reports, and the authority level of historical material are in the [documentation index](./docs/README.md).

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

1. A two-phase `terraform apply`: AWS infrastructure first (VPC, EKS, node groups, S3, IRSA), then in-cluster resources. The split exists because the kubernetes/helm providers need an EKS API endpoint that does not exist until the cluster is built.
2. Install the operator, monitoring, and — only when a `local-nvme` cluster exists — the local-static-provisioner.
3. For **each cluster** in `clickhouse_clusters`: seven preflight checks, render the CHK/CHI templates, apply in order (namespace, backup, Keeper, wait for quorum, CHI), wait for pods, run the smoke test.
4. Apply the shared Grafana dashboard once at the end.

The preflight checks stop known failure modes **before** the CHI is applied: a missing StorageClass or wrong `volumeBindingMode` (which leaves PVCs Pending forever), fewer nodes than `shards × replicas`, a leftover placeholder, or a Keeper that has not reached quorum.

Do not apply the templates under `manifests/templates/` directly. Their placeholders must be rendered by the deployment process.

### 8.1 Adding or Removing a Cluster

The set of clusters *is* the `clickhouse_clusters` map, so **adding a cluster means adding a key**:

```hcl
clickhouse_clusters = {
  ebs = {
    storage_profile = "ebs"
    shards          = 1
    replicas        = 3
  }
  nvme = {
    storage_profile = "local-nvme"
    shards          = 1
    replicas        = 3
  }
}
```

Then re-run `./scripts/deploy.sh`. Existing clusters are not touched: node groups are addressed by string key (`ck-<cluster>-<az>`) rather than list index, so adding or removing one cluster cannot shift another cluster's resource addresses.

To remove a single cluster:

```bash
./scripts/teardown.sh --cluster nvme
```

That deletes only that cluster's CHI, Keeper, namespace, node groups, and StorageClass, and reclaims the EBS volumes its `Retain` policy leaves behind. Afterwards remove the key from `clickhouse_clusters`, or the next apply recreates it.

**Verified on 2026-08-17** ([acceptance record](./docs/perf-results/multi-cluster-verify-20260817-summary.csv)): two 1×3 clusters ran simultaneously on one EKS, `ebs` on 3400 GiB gp3 and `nvme` on 3436 GiB local NVMe, with replication reaching all six replicas. Adding and removing a cluster both produced **zero** `terraform plan` changes on the surviving cluster's addresses, and its six pod UIDs and zero restart counts were unchanged.

## 9. Validation and Access

Each cluster has its own namespace, `ck-<cluster key>`, so every command below carries the cluster key. Using the default `ebs` cluster:

```bash
kubectl -n ck-ebs get chi,chk,pods
CLICKHOUSE_NAMESPACE=ck-ebs CLICKHOUSE_CHI=ebs \
  CLICKHOUSE_ADMIN_PASSWORD='...' ./scripts/smoke-test.sh
```

`deploy.sh` already runs the smoke test once per cluster; the above is how to re-run it afterwards. It reads the expected topology from the CHI and asserts `system.clusters` against it, then validates ReplicatedMergeTree writes, cross-replica synchronization, and that the `system.replicas` queues drain. Topology and replica count are not hardcoded, so clusters that are not 1×3 are covered too.

ClickHouse is available only inside the cluster by default. For temporary access:

```bash
kubectl -n ck-ebs port-forward svc/clickhouse-ebs 8123:8123
curl -u admin:yourpassword "http://localhost:8123/?query=SELECT+version()"
```

The service is named `clickhouse-<cluster key>`, and pods are named `chi-<cluster key>-main-<shard>-<replica>-0`.

## 10. Monitoring

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
```

Monitor replica delay, replication queues, disk usage, merge backlog, query latency, CPU, memory, and network. The repository's dashboard ConfigMap is a starting point; production use requires validation against actual metric names and appropriate alert thresholds.

## 11. Backup and Recovery

Every cluster with backup enabled gets its own daily CronJob, which calls `clickhouse-backup` at `02:00 UTC` and uploads one complete replica of its shard to S3. The bucket is shared, versioned, encrypted, and public-access-blocked, but **each cluster writes to its own prefix**, `s3://<bucket>/<cluster key>/`, and each cluster's IRSA role is authorized only for that prefix — one cluster's backup credentials cannot read or write another's.

Inspect backups (using the `ebs` cluster):

```bash
kubectl -n ck-ebs get cronjob clickhouse-backup-daily
kubectl -n ck-ebs get jobs
cd terraform && terraform output -raw backup_bucket
```

An individual cluster can set `enable_backup = false`, in which case its ServiceAccount, ConfigMap, CronJob, and the CHI sidecar are all left unrendered.

When a local-NVMe node is permanently lost, Kubernetes does not automatically move its PVC to a new node. After confirming that the node will not return and at least one other replica is healthy, run the following (the argument is the StatefulSet name, of the form `chi-<cluster key>-main-<shard>-<replica>`):

```bash
CONFIRM_REPLICA_DATA_LOSS=yes \
  ./scripts/recover-local-replica.sh chi-nvme-main-0-1
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

The ordering is not a matter of style. **The CHI must go first so the EBS CSI driver reclaims the volumes while the control plane is still alive**: data volumes have `DeleteOnTermination` set to `false`, so once the control plane is gone the CSI driver goes with it and nothing is left to delete them — they stay on the bill forever. The gp3 class also uses `reclaimPolicy: Retain`, which is precisely what lets a replacement node reattach the original volume, so deleting a PVC does not delete its volume either. `teardown.sh` therefore reads each PV's `csi.volumeHandle` **before** the namespace is deleted, then deletes the volumes and finishes with a tag-based sweep.

Teardown is also deliberately **re-entrant and free of any Kubernetes API dependency** (it removes helm/kubernetes resources from state before destroying). Both come from measured failures: a dropped SSM tunnel left a `helm_release` stalling for minutes before failing with zero resources destroyed, and a local DNS failure interrupted a run whose delete requests had already taken effect.

### 12.1 Stopping Nodes to Save Money: Check the Storage Medium First

Scaling to zero has **completely different** consequences per profile:

| Profile | Effect of stopping the nodes |
|---|---|
| `ebs` | The volume is independent of the instance and reattaches when the node returns, so **data survives**; you still pay for the volume |
| `local-nvme` | Data lives on instance store, so **stopping the instance destroys it permanently**; recovery means rebuilding from a healthy replica or the lakehouse |

So `local-nvme` has no "stop to save money" option — only destroying it and accepting the rebuild, or switching to `ebs`.

#### 12.1.1 The Correct Order for Scaling to Zero (measured 2026-08-18)

Node groups declare `min_size` of 1 (Keeper is `min = max = 1`), and EKS rejects `desired < min`, so **`min` must come down in the same call**:

```bash
aws eks update-nodegroup-config --cluster-name clickhouse-eks \
  --nodegroup-name "$NG" --region us-east-1 \
  --scaling-config minSize=0,maxSize=1,desiredSize=0
```

**Scale `system` down first, then the data and Keeper groups.** The cluster-autoscaler runs on `system`; if the data groups go first, it sees Pending ClickHouse pods and scales them straight back up, fighting the scale-down. On the way back up the order reverses — CoreDNS, the operator, and the autoscaler all live on `system`, and nothing else reconciles until they are ready.

`terraform apply` is the cleanest way back, since it restores `min_size` to the declared values. But `desired_size` on the ClickHouse groups sits under `ignore_changes` (the autoscaler owns it at runtime), so it may stay at 0 after an apply and needs checking separately.

#### 12.1.2 Scaling Everything to Zero Stalls on the PDB, and That Is Expected

10 of 16 instances were observed sitting in `Terminating:Wait` inside their ASGs for about five minutes. **This is not a failure.** The termination lifecycle hook drains pods first and honors the operator's `maxUnavailable: 1`. The first node in each pool drains normally, but its pod has nowhere to go — every group is heading to zero — so it stays Pending, the PDB never regains headroom, and the remaining evictions block.

The hook is `DefaultResult=CONTINUE` with a 1800-second timeout, so it always proceeds eventually. To release it immediately:

```bash
aws autoscaling complete-lifecycle-action --region us-east-1 \
  --auto-scaling-group-name "$ASG" --lifecycle-hook-name Terminate-LC-Hook \
  --instance-id "$IID" --lifecycle-action-result CONTINUE
```

This is safe when the nodes are going away regardless: ClickHouse is crash-safe against a killed process, and on `ebs` the data volumes are `Retain` and independent of the instance. Do **not** use it during a rolling replacement — skipping the drain discards the protection the PDB exists to provide.

## 13. Scope Boundaries and Documentation Rules

Current non-goals:

- It does not deploy a lakehouse, Glue Catalog, Kafka/MSK, or Flink.
- It does not implement Cloud/OSS dual-write, historical backfill, CDC, deduplication, or result comparison.
- It does not provide a public load balancer, TLS, authentication proxy, or multi-tenant isolation.
- It does not provide automatic sharding, automatic local-PV failure recovery, or elastic scale-out.
- It never defines ClickHouse or the backup bucket as the sole SoT.

`README.md` and `README.en.md` are the synchronized Chinese and English canonical entry points. Their section numbering and technical facts must remain aligned. Research, test reports, and historical implementation plans under `docs/` are supporting artifacts; see [docs/README.en.md](./docs/README.en.md) for authority and version status.
