# ClickHouse on EKS Deployment Design

[中文](./2026-07-03-clickhouse-on-eks-design.md) · **English**

> Date: 2026-07-03
> Deliverable: Reviewable, executable IaC code (written by Claude, with the user running `terraform apply` themselves). **This design does not apply changes to a real AWS account on the user's behalf.**
> Research basis: See [`docs/clickhouse-on-eks-research.en.md`](../../clickhouse-on-eks-research.en.md)
> Current authoritative entry points: Refer to the repository code, [`README.md`](../../../README.md), and [`README.en.md`](../../../README.en.md); this document retains the design background.
> Architectural premise: The upstream data lakehouse holds the sole authoritative data truth. ClickHouse serves only as a derived, eventually consistent, rebuildable OLAP acceleration layer. This repository does not deploy the lakehouse or ingestion pipelines.

---

## 1. Goals and Decision Summary

| Dimension | Decision |
|---|---|
| Deliverable | Reviewable IaC code, applied by the user |
| Data role | **The upstream lakehouse is the sole SoT; ClickHouse is a rebuildable OLAP acceleration layer** |
| Topology | **1 shard × 3 replicas + 3 Keepers** (3 ClickHouse nodes + 3 Keeper nodes) |
| EKS source | New VPC + EKS, **reusing the `eks/` submodule from the Altinity Terraform EKS Blueprint (pinned to v0.5.7)**; hybrid Option 1 |
| Storage | **Local NVMe** (i8g.4xlarge instances, ARM/Graviton), Option A: pinning + three-replica redundancy |
| Network exposure | ClusterIP (in-cluster access) |
| Monitoring | Prometheus + Grafana (kube-prometheus-stack) |
| Backup | clickhouse-backup → S3 (authorized through IRSA) |
| Versions | Pin exact versions (operator 0.27.1 + stable ClickHouse LTS) |

---

## 2. Core Architectural Tradeoff: Local NVMe (Confirmed Option A)

Local NVMe pursues maximum IO performance, but inherently conflicts with the Kubernetes principle that "Pods can move freely," making this the highest-risk aspect of the design. The design uses **Option A**:

- Use `local-static-provisioner` (or `local` PVs) to pin each ClickHouse Pod to a specific i8g.4xlarge node.
- Anti-affinity ensures that **the 3 replicas run on different nodes in different AZs**.
- Permanent node failure → that replica's local data is lost → manually run `scripts/recover-local-replica.sh` to release the failed local PV, after which the operator + Keeper rebuild it from a healthy replica in another AZ.
- **Prerequisites:** the upstream lakehouse can replay data + three replicas + S3 ClickHouse backups. The backup bucket shortens RTO; it is not the sole SoT.
- Cost: After a node failure, recovery must be triggered manually and the full replica data must be fetched again. During recovery, the shard operates in a degraded two-replica state (without service interruption).

**Topology selection principle (scale up first, shard later):** The current design uses 1 shard × 3 replicas rather than multiple shards because ClickHouse sharding has no automatic rebalance mechanism - existing data is not migrated automatically after shards are added, resulting in high operational overhead. Recommended strategy: prioritize vertical scaling (larger i8g instances) and introduce multiple shards only when single-node query performance becomes the bottleneck.

**Keeper exception:** Keeper uses **gp3** rather than local disks. Keeper data is small and must be durable; if one node fails, its PV must be usable to rebuild it elsewhere, which local disks cannot support.

---

## 2.5 Reusing the Altinity EKS Blueprint (Confirmed Hybrid Option 1)

After reviewing the source of upstream `Altinity/terraform-aws-eks-clickhouse` (v0.5.7), the division of responsibilities is:

**Parts reused from the blueprint (mature, developed in official collaboration with AWS, no need to reinvent them):**
- The `//eks` submodule: VPC + subnets across 3 AZs + NAT + EKS cluster + node groups + cluster-autoscaler + IAM. Referenced as a child module (this submodule contains no internal provider blocks and can be consumed cleanly).
- The `//clickhouse-operator` submodule: installs the Altinity operator (version pinned to `0.27.1`, overriding its default `0.24.4`).

**Parts discarded from the blueprint (closed and unable to express this design):**
- The `//clickhouse-cluster` submodule - not used. Its CHI topology is hard-coded in the upstream `clickhouse-eks` Helm chart (0.1.8), and Terraform exposes only zones/instance_type/name/user/password. It **cannot configure a custom shard/replica topology, local NVMe (it hard-codes `gp3-encrypted`), anti-affinity, or backups**. We write our own CHI/CHK manifests instead.

**Blueprint interface constraints (must be observed in the implementation plan):**
- `eks_node_pools` node names are **required** to start with `clickhouse` or `system` (enforced by validation) → name the Keeper node group `system-keeper`.
- Provider version constraints: AWS `~> 5.40`, Helm `>= 2.9, < 3.0`, Kubernetes `>= 2.25.2`.
- The OIDC provider ARN is not exposed in the root outputs → implement clickhouse-backup IRSA in our wrapper using the `data.aws_eks_cluster` + `aws_iam_openid_connect_provider` data sources.

## 3. Overall Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ New VPC (3 AZs: a/b/c)                                      │
│                                                               │
│  ┌──── EKS cluster ─────────────────────────────────────┐    │
│  │                                                        │    │
│  │  Node group 1: system (gp3, general-purpose instances, 3x) │
│  │    ├─ Altinity clickhouse-operator (0.27.1)           │    │
│  │    ├─ kube-prometheus-stack (Prometheus + Grafana)    │    │
│  │    └─ aws-ebs-csi-driver / local-static-provisioner   │    │
│  │                                                        │    │
│  │  Node group 2: clickhouse (i8g.4xlarge, ARM/Graviton, local NVMe, 3x across AZs) │
│  │    ├─ shard0-replica0 (AZ-a)                            │    │
│  │    ├─ shard0-replica1 (AZ-b)                            │    │
│  │    └─ shard0-replica2 (AZ-c)                            │    │
│  │                                                        │    │
│  │  Node group 3: keeper (gp3, small instances, 3x across AZs) │
│  │    └─ keeper-0(a) keeper-1(b) keeper-2(c)  [CHK CRD]   │    │
│  └────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
        │ IRSA                          │ backup
        ▼                               ▼
   ClickHouse Service (ClusterIP)   S3 Bucket (clickhouse-backup)
```

**Design principles:**
- Three independent node groups with isolated responsibilities (system components / ClickHouse / Keeper do not interfere with one another).
- Deploy Keeper independently (CHK CRD), never colocated with ClickHouse - a mandatory best practice from the research report.
- Layered decoupling: Terraform manages AWS infrastructure + Helm add-ons; manifests manage the ClickHouse application topology (CHI/CHK). The CHI topology can be changed without modifying Terraform.

---

## 4. Code Structure (Deliverables)

```
clickhouse-deployment/
├── docs/
│   ├── clickhouse-on-eks-research.md        # Existing research
│   ├── README.md                            # Document authority levels and status index
│   └── superpowers/specs/2026-07-03-...-design.md  # This design document
├── terraform/
│   ├── versions.tf          # Provider constraints (aws ~>5.40, helm <3, k8s >=2.25) + backend
│   ├── providers.tf         # aws/kubernetes/helm providers (targeting EKS, token via exec)
│   ├── eks.tf               # module "eks" → Altinity blueprint //eks submodule (v0.5.7)
│   ├── operator.tf          # module "operator" → blueprint //clickhouse-operator (pinned to 0.27.1)
│   ├── storage.tf           # gp3 StorageClass + local-static-provisioner (Helm)
│   ├── monitoring.tf        # kube-prometheus-stack (Helm)
│   ├── irsa.tf              # OIDC data source + IAM role/policy for clickhouse-backup
│   ├── s3.tf                # Backup bucket (encryption/public access blocked/versioning)
│   ├── variables.tf         # Region, AZs, instance types, access CIDRs, and other parameters
│   ├── outputs.tf           # kubeconfig command, service address, bucket name
│   └── terraform.tfvars     # Pinned defaults (review this before apply)
├── manifests/
│   ├── 00-namespace.yaml
│   ├── 05-nvme-bootstrap.yaml     # Format and mount instance-store NVMe
│   ├── 10-keeper-chk.yaml         # ClickHouseKeeperInstallation, 3 nodes
│   ├── 20-clickhouse-chi.yaml     # ClickHouseInstallation, 1x3 + anti-affinity + local disks
│   ├── 30-backup-cronjob.yaml     # clickhouse-backup → S3
│   └── 40-grafana-dashboard.yaml  # Dashboard #12163 ConfigMap
├── scripts/
│   ├── deploy.sh            # Orchestration: terraform apply → install CRD → apply manifests
│   ├── smoke-test.sh        # Create distributed table, write, verify across replicas, query system.replicas
│   ├── recover-local-replica.sh # Guarded recovery process after permanent loss of an NVMe node
│   └── teardown.sh          # Ordered destruction (delete CHI before terraform destroy)
├── README.md               # Authoritative Chinese entry point
└── README.en.md            # Authoritative English entry point, synchronized with the Chinese version
```

---

## 5. Key Implementation Details

1. **Local-disk pinning:** The ClickHouse node group uses i8g.4xlarge (ARM/Graviton, ~3.75TB NVMe, 3400Gi data volume per replica); `local-static-provisioner` discovers NVMe → local PV; the CHI `dataVolumeClaimTemplate` uses the `local-storage` StorageClass (`WaitForFirstConsumer`).
2. **Anti-affinity + cross-AZ placement:** In the CHI `podTemplate`, `podAntiAffinity` (topologyKey=`kubernetes.io/hostname`, with each of the three replicas on a different host) + `topologySpreadConstraints` (topology.kubernetes.io/zone across AZs).
3. **Resource model (dedicated nodes):** Each i8g.4xlarge node runs only one ClickHouse Pod (one-pod-per-dedicated-node). Set a high CPU request (such as `"14"`) but **no CPU limit** - avoiding CFS throttling that would hurt latency during query bursts; memory request == limit (`"110Gi"`) ensures Guaranteed QoS and prevents OOM eviction; CHI configures `max_server_memory_usage_to_ram_ratio: "0.9"` to leave approximately 10% headroom for the page cache.
4. **Keeper:** Independent CHK, 3 nodes across AZs, gp3 PVCs; CHI references the CHK service through its `zookeeper` configuration.
5. **Backups:** clickhouse-backup runs as a CronJob with IRSA-authorized access to S3, with daily full + optional incremental backups. This bucket is an auxiliary recovery point and does not replace the upstream lakehouse SoT.
6. **Version pinning:** operator `0.27.1`; ClickHouse/Keeper images are pinned to `25.3` LTS in the manifests. An upgrade must update both images and rerun testing.
7. **Secure defaults:** ClusterIP; S3 bucket encryption + blocked public access + versioning; node groups placed in private subnets.

---

## 6. Validation and Test Strategy

`smoke-test.sh` performs end-to-end validation (not just "Pod Running"):
- Create `ReplicatedMergeTree` + `Distributed` tables
- Write to one replica → query another replica to confirm synchronization (validates that Keeper works)
- Inspect `system.replicas` / `system.clusters` to check topology health
- Kill one ClickHouse Pod → confirm that another replica remains queryable (validates HA)

---

## 7. Cost and Security Notices (Stated Explicitly in the README)

- The current design includes 3× i8g.4xlarge, 3× Keeper, 3× system, 1× benchmark, NAT, and the EKS control plane. Prices change; consult the AWS Pricing Calculator before apply.
- The teardown script ensures ordered destruction (delete CHI/CHK first so the operator cleans up → then run terraform destroy), preventing orphaned EBS/NLB resources from continuing to incur charges; the S3 backup bucket is retained and removed from Terraform state.

---

## 8. Non-Goals (YAGNI)

- No public exposure and no TLS termination (start with ClusterIP; add Ingress/NLB later as needed).
- No multi-cluster / multi-tenant support.
- No automatic scaling policy tuning (node groups use fixed capacity; leave the autoscaling switch available but do not tune it deeply).
- Do not deploy a lakehouse, Kafka/Flink pipelines, Cloud/OSS dual writes, or historical backfills.
- Do not execute apply on the user's behalf.

---

## 9. Open Items / User Confirmation Required Before Apply

- The next ClickHouse/Keeper LTS upgrade window and compatibility validation plan.
- The AWS region and exact names of the 3 AZs (parameterized; defaults are placeholders for the user to fill in).
- i8g instance size (default `i8g.4xlarge`, adjustable in tfvars; `clickhouse_ami_type` defaults to `AL2023_ARM_64_STANDARD` and must also be changed when switching to an x86 instance). When scaling up to larger instances (such as `i8g.8xlarge` / `i8g.12xlarge`) for load testing, the CPU/memory resource requests and data volume size in the CHI must also be adjusted manually (the current values are tailored to i8g.4xlarge).
