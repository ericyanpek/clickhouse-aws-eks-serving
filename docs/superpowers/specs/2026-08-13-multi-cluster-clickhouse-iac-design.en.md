# Multi-Cluster ClickHouse on EKS IaC Design

[中文](./2026-08-13-multi-cluster-clickhouse-iac-design.md) · **English**

> Status: design approved, implementation pending.
> Goal: bring up one or more mutually independent ClickHouse clusters on demand under a single EKS control plane, with topology, storage, instance size, and version independently customizable per cluster.
> Project boundary unchanged: the upstream lakehouse holds the sole authoritative source of truth (SoT); ClickHouse is a rebuildable OLAP acceleration layer.

## 1. Problem Statement

The current IaC can only bring up **one** cluster with a fixed 1 shard × 3 replicas topology:

- [`manifests/templates/20-clickhouse-chi.yaml.tmpl`](../../../manifests/templates/20-clickhouse-chi.yaml.tmpl) is static YAML with `shardsCount: 1` and `replicasCount: 3` hardcoded, along with fixed name and namespace.
- Node pools are managed by the upstream Altinity module, which keys node groups by **list index**.
- IRSA, backup, and StorageClass all assume a single cluster in a single namespace.

The node-group keying mechanism is the hardest constraint. From upstream `eks/main.tf:89`:

```hcl
eks_managed_node_groups = { for idx, np in local.node_pool_combinations : "node-group-${tostring(idx)}" => {
```

**The key is the list position index.** So any change to list length or order shifts the addresses of every subsequent node group, and Terraform decides they must be rebuilt — including node groups currently serving traffic. This was hit in practice during this work: disabling one flag removed an entry from the head of the list, and `plan` showed live node groups being rebuilt. `node-group-10` still has an orphaned launch template today.

This conflicts directly with the goal: **adding or removing a cluster must never affect the others.**

## 2. Goals and Non-Goals

### 2.1 Goals

| Dimension | Requirement |
|---|---|
| Concurrency | Multiple ClickHouse clusters may exist under one EKS; only `ebs` starts by default, others are added on demand |
| Robustness | Clusters are independent and do not affect each other; startup is trustworthy and does not error midway; runtime is stable |
| Extensibility | Start with one, add a second at any time; adding and removing must not touch existing clusters |
| Customizability | Per cluster: topology (shards × replicas), storage medium and capacity, instance size and resource quotas, ClickHouse version and configuration |

The **quantified acceptance criterion** for robustness: when adding or removing a cluster, `terraform plan` must show **zero changes** on the existing clusters' resource addresses. "Looks fine" is not accepted.

### 2.2 Non-Goals

- No cross-AZ or multi-region orchestration across several EKS clusters; this design is scoped to one EKS.
- No Karpenter. It is closer to the elasticity goal but introduces a new component and requires redesigning the local-NVMe path, which works against "startup must be trustworthy."
- No change to the premise that the lakehouse is the sole SoT.
- No cross-cluster data migration or federated queries.

## 3. Architecture

### 3.1 Cluster Identity and Derivation

Introduce a `clickhouse_clusters` map where **the map key is the stable identifier for every resource**:

```hcl
clickhouse_clusters = {
  ebs = {
    storage_profile = "ebs"
    shards          = 1
    replicas        = 3
  }
  # To add a second cluster, uncomment. This does not affect ebs:
  # nvme = {
  #   storage_profile = "local-nvme"
  #   shards          = 1
  #   replicas        = 2
  # }
}
```

Each key derives a complete, non-overlapping set of resources:

| Resource | Naming | Isolation level |
|---|---|---|
| Kubernetes namespace | `ck-<key>` | Fully isolated |
| CHI | `<key>`, internal cluster name `main` | Independent |
| Keeper (CHK) | `keeper-<key>`, 3 nodes | **Dedicated set per cluster** |
| Data node groups | `for_each` key = `<key>-<az>` | **Map-keyed; add/remove does not disturb others** |
| Keeper node groups | `for_each` key = `<key>-kp-<az>` | Same |
| StorageClass | `ck-<key>-gp3` or `ck-<key>-local` | Independent tier per cluster |
| Keeper ZooKeeper path | `/clickhouse/<key>/...` | Logically isolated |
| IRSA role | `<cluster_name>-ck-<key>-backup` | Permission isolation |
| S3 backup prefix | `s3://<bucket>/<key>/` | Data isolation |

Keeper is **one dedicated set per cluster** rather than shared. Sharing would save about $178.70/month per cluster, but the quorum would become a failure domain shared across clusters — losing quorum would strip replication from every cluster at once, which conflicts with cluster independence.

### 3.2 Taking Over Node Groups (Core Mechanism)

The upstream module continues to own VPC / EKS / addons / autoscaler and the **shared node pools** (`system`, `bench`), whose count is fixed and therefore cannot shift. ClickHouse and Keeper node groups become self-managed:

```hcl
locals {
  # One node group per (cluster, AZ); the key is a string, not an index
  ck_node_groups = merge([
    for name, c in var.clickhouse_clusters : {
      for az in c.zones : "${name}-${az}" => { cluster = name, az = az, ... }
    }
  ]...)
}

resource "aws_eks_node_group" "ck" {
  for_each = local.ck_node_groups
  ...
}
```

**Why this is smooth:** `for_each` keys are strings. Removing the `nvme` key destroys only `nvme-*` resources; every `ebs-*` address stays exactly as it was, with no shifting.

**One subnet per AZ is deliberate.** A gp3 volume is an AZ-scoped resource, and pinning a node group to a single subnet is what guarantees a replacement node lands in the volume's AZ so the original volume can reattach. This mechanism was validated in the [2026-08-13 HA drill](../../ha-drill-report.en.md): after permanent node loss the volume reattached in 111 seconds with zero data rebuild.

### 3.3 Obtaining External Dependencies

The upstream module exposes only five outputs, excluding the node IAM role and subnets. All three dependencies are obtainable without modifying upstream, and each has been verified:

| Dependency | How it is obtained | Verification |
|---|---|---|
| Node IAM role | `data.aws_iam_role`, name = `${cluster_name}-eks-node-role` | Upstream `iam.tf:45` confirms the naming; this repository's [`ssm.tf`](../../../terraform/ssm.tf) already uses the same pattern |
| Per-AZ private subnet | `data.aws_subnets`, filter tag Name = `${cluster_name}-vpc-private-${az}` | Confirmed against the live subnet tags |
| Cluster name / CA / endpoint | Upstream outputs and `data.aws_eks_cluster` | Already exposed |

### 3.4 Node Group Attributes That Must Be Carried Over

Upstream `eks/main.tf:89-115` provides the full attribute list. Once self-managed, each of the following must be declared explicitly; omitting one causes a specific failure:

| Attribute | Consequence if omitted |
|---|---|
| `iam_role_arn` with `create_iam_role = false` | Nodes cannot join the cluster |
| tag `k8s.io/cluster-autoscaler/enabled = "true"` | The autoscaler does not recognize the node group |
| tag `k8s.io/cluster-autoscaler/<cluster_name> = "owned"` | Same |
| taint `dedicated=clickhouse:NoSchedule` | Upstream adds this automatically for pools whose name starts with `clickhouse`; once self-managed it must be declared, or other workloads will land on data nodes |
| `labels`: `workload`, `storage`, `ck-cluster = <key>` | The CHI nodeSelector cannot target this cluster's own node pool |
| `ami_type`, `disk_size`, `instance_types`, `subnet_ids` | Wrong node size or placement |

Each item must be checked against the upstream source during implementation.

### 3.5 CHI and CHK Become Rendered Templates

The CHI changes from static YAML to a template rendered by `deploy.sh`, with these fields coming from each cluster's entry in the map: `shardsCount`, `replicasCount`, container CPU/memory requests and limits, `storageClassName`, volume capacity, image version, nodeSelector (including `ck-cluster`), and the Keeper reference plus ZooKeeper path prefix.

The current CHI resource values are hand-sized to `i8g.4xlarge`; once parameterized they must track the instance size so quotas and instance capacity cannot diverge.

## 4. Deployment and Lifecycle

### 4.1 Deployment Flow

```
1. terraform apply phase 1 → VPC / EKS / addons / shared pools (independent of cluster count)
2. terraform apply phase 2 → per-cluster node groups, StorageClass, IRSA
3. For each cluster in the map:
     3a. Preflight checks
     3b. Render the CHK and CHI templates
     3c. Apply in order: namespace → backup → CHK → wait for Keeper Ready → CHI
     3d. Wait for readiness and run the smoke test
```

The two-phase apply keeps its existing rationale: the kubernetes/helm providers need a reachable cluster API, which does not exist until the first apply completes.

### 4.2 Preflight Checks (Delivering Trustworthy Startup)

Each cluster validates the following **before** the CHI is applied. Any failure exits with an actionable message:

| Check | Consequence of not checking |
|---|---|
| StorageClass exists | PVCs stay Pending indefinitely with no obvious error |
| `volumeBindingMode = WaitForFirstConsumer` | An AZ-scoped volume may bind in the wrong AZ |
| Node groups Ready and count equals shards × replicas | Pods stay Pending for an obscure reason |
| For `local-nvme`, NVMe is formatted and mounted | PVCs stay Pending |
| For `ebs`, the EBS CSI DaemonSet is present | Volumes cannot be provisioned |
| No leftover `REPLACE_WITH` placeholder | Authentication or backup fails silently |
| Keeper quorum is ready | The CHI restarts repeatedly |

Each check corresponds to a failure mode actually encountered during this work.

### 4.3 Per-Cluster Teardown

- `teardown.sh --cluster <key>`: destroys only that cluster's CHI, CHK, namespace, node groups, and StorageClass, leaving other clusters untouched.
- `teardown.sh`: destroys everything; the S3 backup bucket is retained and removed from Terraform state per the existing logic.

Because node groups are map-keyed, destroying one cluster does not change any other cluster's Terraform addresses.

The `-target` list for storage resources in [`teardown.sh`](../../../scripts/teardown.sh) has already been changed to read from `terraform state list` dynamically, so it tolerates count-gated resource addresses.

### 4.4 Migration Path

The existing cluster carries experiment residue: the `node-group-10` orphaned launch template, storage class configuration drift, and two parallel comparison CHIs. Existing node groups also have state addresses (`module.eks.module.eks.module.eks_managed_node_group["node-group-N"]`) that cannot be mapped cleanly onto the new addresses (`aws_eks_node_group.ck["ebs-us-east-1a"]`).

The approach is therefore **destroy first, then rebuild with the new IaC**. Measured results (storage selection, HA drill) are fully archived under `docs/` and `results/`, so destroying loses no conclusions; re-measuring requires reloading data.

## 5. Verification Plan

"It actually brings up a cluster" is a precondition for accepting this design, so verification is based on real deployment rather than static checks alone.

| Step | Action | Pass criterion |
|---|---|---|
| 1 | `terraform validate` and `plan` review | Resource addresses and tags match the design |
| 2 | Destroy the existing cluster, apply the default configuration from scratch (`ebs` only) | Smoke test passes |
| 3 | Add the `nvme` cluster | `plan` shows **zero changes** on `ebs-*` addresses; both clusters healthy after apply |
| 4 | Remove the `nvme` cluster | `plan` shows **zero changes** on `ebs-*` addresses |
| 5 | Check autoscaler recognition and taint effectiveness | Node groups are recognized by the autoscaler; other workloads cannot schedule onto data nodes |

Steps 3 and 4 are the quantified acceptance criteria for independence.

**Cost note:** step 3 runs two clusters concurrently for a short period. At 1 shard × 3 replicas on `r8g.4xlarge` with 20k IOPS / 1250 MiB/s gp3, one cluster runs at roughly $3,449/month (about $2,064 for data nodes, $179 for Keeper, $1,206 for volumes), plus roughly $196/month of shared cost. During verification the second cluster can use smaller instances and volumes, since its only purpose is to prove that adding a cluster does not disturb the existing one.

## 6. Risks and Mitigations

| Risk | Mitigation |
|---|---|
| Missing an upstream node-group attribute, breaking autoscaler recognition or the taint | Check each item against upstream `eks/main.tf:89-115` during implementation; verification step 5 targets this specifically |
| Upstream module upgrade changes naming (node role, subnet tags) | The dependency points are the three data sources in 3.3; re-verify them together on upgrade. The module version is pinned to `v0.5.7` |
| Shared autoscaler behavior across multiple clusters is unverified | Covered by verification step 5; split autoscaler priorities per cluster if needed |
| A dedicated Keeper per cluster raises cost | Accepted as an explicit tradeoff; only one cluster runs by default |
| Template parameterization introduces rendering errors | Preflight includes a leftover-placeholder check; the smoke test verifies actual topology against expectations |

## 7. Deferred

Out of scope here, but recorded:

- HA drill for the local-NVMe profile (requires a symmetric cross-AZ topology).
- P8 node-failure drill under sustained write load.
- Performance-neutrality verification after the gp3 tier reduction — not yet measured, so figures must not be subtracted directly from pre-reduction numbers.
