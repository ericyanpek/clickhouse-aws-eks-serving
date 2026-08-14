# 多集群 ClickHouse on EKS IaC 实现计划

**中文** · [English](./2026-08-14-multi-cluster-clickhouse-iac.en.md)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让一套 EKS 能按需拉起一个或多个相互独立的 ClickHouse 集群，每个集群的拓扑、存储、实例规格和版本均可独立配置，且增删任一集群不影响其他集群。

**Architecture:** 引入 `clickhouse_clusters` map 变量，map 的 key 成为所有派生资源的稳定标识符。ClickHouse 与 Keeper 节点组从上游 Altinity 模块（index-keyed，会位移）迁出，改为自管 `aws_eks_node_group` + `for_each`（map-keyed，稳定）。上游模块继续负责 VPC / EKS / addons 与数量固定的共享池。CHI/CHK 从静态 YAML 改为 `deploy.sh` 渲染的模板。

**Tech Stack:** Terraform 1.5+、AWS Provider 5.x、Altinity ClickHouse Operator 0.27.1、ClickHouse/Keeper 25.3 LTS、bash + kubectl、Amazon EKS 1.34。

**设计依据:** [`docs/superpowers/specs/2026-08-13-multi-cluster-clickhouse-iac-design.md`](../specs/2026-08-13-multi-cluster-clickhouse-iac-design.md)

## 前置状态

执行本计划前的实际状态（已核实）：

- AWS 侧已彻底清空：EKS 集群已删除、13 台实例终止、5 个 EBS 卷已回收、Terraform state 为 0 个资源。可以从零 apply。
- S3 备份桶 `clickhouse-eks-ch-backups` 已保留并移出 state（桶内 0 对象）。
- 工作区有 7 个文件的**未提交改动**（`storage_profile` 全局变量方案）：`terraform/{variables,storage,eks,outputs}.tf`、`scripts/{deploy,teardown}.sh`、`manifests/20-clickhouse-chi.yaml`。本计划**不单独提交这个中间态**，Task 1 会直接把它改造为 map 方案。

## 关键约束（来自实测，不可违反）

1. **上游模块 index-keyed。** `eks/main.tf:89` 用列表序号做 key，列表长度或顺序一变就导致活跃节点组重建。因此 ClickHouse/Keeper 节点组必须迁出。
2. **单 AZ 单子网。** gp3 卷是 AZ 绑定资源，节点组必须绑定单一子网，替换节点才能落在同 AZ 重挂原卷（P8 演练验证：111 秒重挂、零重建）。
3. **不要手写 PodDisruptionBudget。** operator 已自建（`maxUnavailable: 1`），重叠 PDB 会让 Pod 永久不可驱逐。
4. **teardown 必须先删 CHI 再拆控制面。** 卷的 `DeleteOnTermination=False`，若控制面先消失，EBS CSI 驱动随之消失，卷会永久留存无人回收。
5. **teardown 不能依赖 Kubernetes API 且必须可重入。** 三次 destroy 的实测教训：tunnel 中断会让 helm_release 卡死 5 分钟后失败；DNS 失败会中断但删除请求已生效。

---

## Task 1: 用 clickhouse_clusters map 替换 storage_profile

把未提交的全局 `storage_profile` 下沉为每集群参数。

**Files:**
- Modify: `terraform/variables.tf`（替换 `storage_profile`、`clickhouse_gp3_iops`、`clickhouse_gp3_throughput_mibps`、`clickhouse_instance_type`）
- Modify: `terraform/eks.tf:1-9`（替换 locals）

- [ ] **Step 1: 删除全局 storage_profile 及其衍生变量**

在 `terraform/variables.tf` 中删除以下四个变量块（它们是未提交的中间态）：`storage_profile`、`clickhouse_gp3_iops`、`clickhouse_gp3_throughput_mibps`，以及 `clickhouse_instance_type`。

- [ ] **Step 2: 新增 clickhouse_clusters map 变量**

在 `terraform/variables.tf` 中 `vpc_cidr` 之后插入：

```hcl
variable "clickhouse_clusters" {
  # The map key is the cluster identifier and doubles as the node-group for_each key.
  # Because keys are strings rather than list indexes, adding or removing a cluster
  # cannot change another cluster's Terraform addresses -- that is the core of this design.
  # Keys must be lowercase alphanumeric with hyphens: they become part of namespace,
  # CHI, and StorageClass names.
  description = "ClickHouse clusters to bring up. Defaults to a single ebs cluster; add a key to add a cluster."
  type = map(object({
    storage_profile      = optional(string, "ebs")
    shards               = optional(number, 1)
    replicas             = optional(number, 3)
    zones                = optional(list(string), ["us-east-1a", "us-east-1b", "us-east-1c"])
    instance_type        = optional(string, "")
    gp3_iops             = optional(number, 20000)
    gp3_throughput_mibps = optional(number, 1250)
    data_volume_size_gib = optional(number, 3400)
    clickhouse_image     = optional(string, "clickhouse/clickhouse-server:25.3")
    keeper_image         = optional(string, "clickhouse/clickhouse-keeper:25.3")
    cpu_request          = optional(string, "14")
    memory_request       = optional(string, "110Gi")
    keeper_instance_type = optional(string, "m7g.large")
    enable_backup        = optional(bool, true)
  }))

  default = {
    ebs = {
      storage_profile = "ebs"
      shards          = 1
      replicas        = 3
    }
  }

  validation {
    condition     = alltrue([for k, v in var.clickhouse_clusters : can(regex("^[a-z0-9-]+$", k))])
    error_message = "Cluster keys may contain only lowercase letters, digits, and hyphens."
  }

  validation {
    condition     = alltrue([for k, v in var.clickhouse_clusters : contains(["ebs", "local-nvme"], v.storage_profile)])
    error_message = "storage_profile must be \"ebs\" or \"local-nvme\"."
  }

  validation {
    # One pod per node and one node group per AZ, so total pods must divide evenly
    # across AZs. shards is included because the CHI provisions shards x replicas
    # pods while the node groups must supply a node for each of them.
    condition     = alltrue([for k, v in var.clickhouse_clusters : (v.shards * v.replicas) % length(v.zones) == 0])
    error_message = "shards x replicas must be a multiple of the number of zones (each AZ carries an equal share)."
  }

  validation {
    condition     = alltrue([for k, v in var.clickhouse_clusters : v.replicas >= 1 && v.shards >= 1])
    error_message = "shards and replicas must both be at least 1."
  }

  validation {
    # Keeper places one member per AZ, so an even AZ count yields an even Raft
    # ensemble, which tolerates no failures at all.
    condition     = alltrue([for k, v in var.clickhouse_clusters : length(v.zones) % 2 == 1])
    error_message = "zones must contain an odd number of AZs so the Keeper ensemble forms a real quorum."
  }

  validation {
    # A duplicate AZ would otherwise surface as "Two different items produced the
    # key" from deep inside a for expression, pointing at nothing the user typed.
    condition     = alltrue([for k, v in var.clickhouse_clusters : length(distinct(v.zones)) == length(v.zones)])
    error_message = "zones must not contain duplicate availability zones."
  }

  validation {
    # gp3 hard limit: throughput may not exceed 0.25x provisioned IOPS.
    condition     = alltrue([for k, v in var.clickhouse_clusters : v.gp3_throughput_mibps <= v.gp3_iops * 0.25])
    error_message = "gp3 throughput in MiB/s must not exceed 0.25 times the provisioned IOPS."
  }

  validation {
    # Only Graviton families are supported: node groups use an ARM64 AMI. An x86
    # instance type would otherwise pair with an ARM AMI and fail mid-apply with an
    # EKS API error that names nothing the user wrote.
    condition = alltrue([
      for k, v in var.clickhouse_clusters :
      can(regex("^(r8g|r7g|i8g|i7g|m8g|m7g|c8g|c7g)\\.", v.instance_type != "" ? v.instance_type : "r8g.4xlarge")) &&
      can(regex("^(r8g|r7g|i8g|i7g|m8g|m7g|c8g|c7g)\\.", v.keeper_instance_type))
    ])
    error_message = "instance_type and keeper_instance_type must be Graviton families (r8g/r7g/i8g/i7g/m8g/m7g/c8g/c7g), because node groups use an ARM64 AMI."
  }
}
```

- [ ] **Step 3: 替换 eks.tf 的 locals**

把 `terraform/eks.tf` 开头的 locals 块（当前是 `clickhouse_instance_type` 与 `storage_profile_is_ebs`）整块替换为：

```hcl
locals {
  # 每个 (集群, AZ) 一个节点组。key 是字符串，增删集群不影响其他集群的地址。
  ck_node_groups = merge([
    for name, c in var.clickhouse_clusters : {
      for az in c.zones : "${name}-${az}" => {
        cluster       = name
        az            = az
        instance_type = c.instance_type != "" ? c.instance_type : (c.storage_profile == "ebs" ? "r8g.4xlarge" : "i8g.4xlarge")
        # The CHI provisions shards x replicas pods, and pod anti-affinity is
        # required on kubernetes.io/hostname, so every pod needs its own node.
        # Omitting shards here would strand (shards-1) x replicas pods Pending
        # forever. Validation guarantees this divides evenly.
        nodes_per_az = (c.shards * c.replicas) / length(c.zones)
        storage      = c.storage_profile == "ebs" ? "ebs-gp3" : "local-nvme"
      }
    }
  ]...)

  kp_node_groups = merge([
    for name, c in var.clickhouse_clusters : {
      for az in c.zones : "${name}-${az}" => {
        cluster       = name
        az            = az
        instance_type = c.keeper_instance_type
      }
    }
  ]...)

  # 只在存在 ebs 集群时才需要 gp3 StorageClass
  ebs_clusters = { for k, v in var.clickhouse_clusters : k => v if v.storage_profile == "ebs" }
  # 只在存在 local-nvme 集群时才需要 local-storage class 与 provisioner
  has_local_nvme = anytrue([for v in var.clickhouse_clusters : v.storage_profile == "local-nvme"])
}
```

- [ ] **Step 4: 验证语法**

Run: `terraform fmt -recursive && terraform -chdir=terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 5: 验证 map 展开正确**

Run:
```bash
cd terraform && terraform console <<'EOF'
local.ck_node_groups
EOF
```
Expected: 三个 key（`ebs-us-east-1a`、`ebs-us-east-1b`、`ebs-us-east-1c`），每个 `nodes_per_az = 1`、`instance_type = "r8g.4xlarge"`、`storage = "ebs-gp3"`。

- [ ] **Step 6: 提交**

```bash
git add terraform/variables.tf terraform/eks.tf
git commit -m "feat(tf): replace global storage_profile with a clickhouse_clusters map

The map key becomes the stable identifier for every derived resource. Because
for_each keys are strings rather than list indexes, adding or removing a
cluster cannot shift another cluster's Terraform addresses."
```

---

## Task 2: 共享池只留 system 与 bench

ClickHouse/Keeper 节点组迁出上游模块，`node_pools` 只保留数量固定的共享池，从此不会位移。

**Files:**
- Modify: `terraform/eks.tf`（`node_pools` 块）

- [ ] **Step 1: 精简 node_pools**

把 `terraform/eks.tf` 中整个 `node_pools = concat(...)` 表达式替换为一个固定长度的列表。删除所有 `clickhouse`、`clickhouse-ebs`、`clickhouse-local-benchmark` 池，以及 `system-keeper` 池（Keeper 改为自管）：

```hcl
  # 只保留与集群数量无关的共享池，因此列表长度恒定，上游的 index-keyed 命名不会位移。
  # ClickHouse 与 Keeper 节点组由本仓库自管（见 nodegroups.tf），以获得 map-keyed 稳定性。
  node_pools = [
    {
      name          = "system"
      instance_type = var.system_instance_type
      ami_type      = "AL2023_ARM_64_STANDARD"
      disk_size     = 50
      desired_size  = 1 # PER AZ → 3 zones × 1 = 3 system nodes
      min_size      = 1
      max_size      = 2
      zones         = var.availability_zones
      labels        = { "workload" = "system" }
      taints        = []
    },
    {
      name          = "system-bench"
      instance_type = var.bench_instance_type
      ami_type      = "AL2023_ARM_64_STANDARD"
      disk_size     = 100
      desired_size  = 1
      min_size      = 1
      max_size      = 1
      zones         = [var.availability_zones[0]]
      labels        = { "workload" = "bench" }
      taints = [{
        key    = "dedicated"
        value  = "bench"
        effect = "NO_SCHEDULE"
      }]
    },
  ]
```

- [ ] **Step 2: 删除已无用的变量**

从 `terraform/variables.tf` 删除以下变量块（其功能已由 `clickhouse_clusters` 承接）：`enable_local_nvme`、`enable_local_nvme_comparison`、`local_nvme_comparison_zones`、`local_nvme_comparison_nodes_per_zone`、`local_nvme_comparison_instance_type`、`enable_ebs_comparison`、`ebs_comparison_zones`、`ebs_comparison_instance_type`、`ebs_comparison_iops`、`ebs_comparison_throughput_mibps`、`ebs_comparison_volume_size_gib`、`clickhouse_zones`、`clickhouse_ami_type`、`keeper_instance_type`。

- [ ] **Step 3: 删除引用这些变量的 outputs**

从 `terraform/outputs.tf` 删除：`ebs_comparison`、`ebs_comparison_volume_size_gib`、`ebs_comparison_replica_count`、`local_nvme_comparison`、`local_nvme_comparison_replica_count`、`storage_profile`、`clickhouse_storage_class`、`clickhouse_instance_type`。

- [ ] **Step 4: 验证无悬空引用**

Run: `terraform -chdir=terraform validate`
Expected: `Success!`。若报 `Reference to undeclared input variable`，说明还有 `.tf` 文件引用了已删变量，按报错逐个清理。

- [ ] **Step 5: 提交**

```bash
git add terraform/eks.tf terraform/variables.tf terraform/outputs.tf
git commit -m "refactor(tf): reduce upstream node_pools to fixed shared pools only

ClickHouse and Keeper node groups move to self-managed for_each resources, so
the upstream list now has constant length and its index-derived node group
names can no longer shift when cluster configuration changes."
```

---

## Task 3: 自管 ClickHouse 与 Keeper 节点组

**Files:**
- Create: `terraform/nodegroups.tf`
- Reference: 上游属性清单在 `terraform/.terraform/modules/eks/eks/main.tf:89-115`

- [ ] **Step 1: 创建三个 data source**

新建 `terraform/nodegroups.tf`，先写数据源。上游模块不暴露 node role 与子网，须反查：

```hcl
# 上游模块在内部创建 node role 但不暴露它。命名规则见
# .terraform/modules/eks/eks/iam.tf:45 —— "${cluster_name}-eks-node-role"。
# scripts/ssm.tf 已用同一模式，此处复用同一约定。
data "aws_iam_role" "node" {
  name       = "${var.cluster_name}-eks-node-role"
  depends_on = [module.eks]
}

# 每个 AZ 一个私有子网。单子网绑定是 gp3 卷能重挂的前提：卷是 AZ 绑定资源，
# 若节点组跨多子网，替换节点可能落到其他 AZ 而无法挂载原卷。
data "aws_subnets" "private_by_az" {
  for_each = toset(var.availability_zones)

  # Scoped to this cluster's VPC on purpose. Filtering by name tag alone would also
  # match an identically named subnet in another VPC in the same account, and the
  # extra ID would silently widen the node group across AZs -- defeating the very
  # pinning this lookup exists to guarantee.
  filter {
    name   = "vpc-id"
    values = [data.aws_eks_cluster.this.vpc_config[0].vpc_id]
  }

  filter {
    name   = "tag:Name"
    values = ["${var.cluster_name}-vpc-private-${each.key}"]
  }

  lifecycle {
    postcondition {
      condition     = length(self.ids) == 1
      error_message = "Expected exactly one private subnet named ${var.cluster_name}-vpc-private-${each.key}, found ${length(self.ids)}. Node groups must be pinned to a single subnet so an AZ-scoped gp3 volume can be reattached."
    }
  }

  depends_on = [module.eks]
}
```

- [ ] **Step 2: 写 ClickHouse 节点组**

追加到 `terraform/nodegroups.tf`：

```hcl
resource "aws_eks_node_group" "clickhouse" {
  for_each = local.ck_node_groups

  cluster_name    = module.eks.cluster_name
  node_group_name = "ck-${each.key}"
  node_role_arn   = data.aws_iam_role.node.arn
  subnet_ids      = data.aws_subnets.private_by_az[each.value.az].ids
  instance_types  = [each.value.instance_type]
  ami_type        = "AL2023_ARM_64_STANDARD"
  disk_size       = 50 # 根卷；数据在 gp3 数据卷或 instance store 上

  scaling_config {
    desired_size = each.value.nodes_per_az
    min_size     = each.value.nodes_per_az
    # 留一个位置供滚动替换。ebs profile 下替换节点重挂原卷；
    # local-nvme 下替换节点是空盘，需 scripts/recover-local-replica.sh。
    max_size = each.value.nodes_per_az + 1
  }

  labels = {
    workload   = "clickhouse"
    storage    = each.value.storage
    ck-cluster = each.value.cluster # CHI 的 nodeSelector 靠这个锚定到本集群的池
  }

  # 上游对 name 以 clickhouse 开头的池自动加这个 taint；自管后必须显式声明，
  # 否则其他负载会混跑到数据节点上。
  taint {
    key    = "dedicated"
    value  = "clickhouse"
    effect = "NO_SCHEDULE"
  }

  tags = {
    # 少了这两个 tag，cluster-autoscaler 不会识别该节点组。
    "k8s.io/cluster-autoscaler/enabled"               = "true"
    "k8s.io/cluster-autoscaler/${var.cluster_name}"   = "owned"
  }

  lifecycle {
    # desired_size 由 autoscaler 在运行期调整，不应被 Terraform 拉回。
    ignore_changes = [scaling_config[0].desired_size]
  }
}
```

- [ ] **Step 3: 写 Keeper 节点组**

追加到 `terraform/nodegroups.tf`。每集群一套独立 Keeper，避免共享 quorum 成为跨集群故障域：

```hcl
resource "aws_eks_node_group" "keeper" {
  for_each = local.kp_node_groups

  cluster_name    = module.eks.cluster_name
  node_group_name = "kp-${each.key}"
  node_role_arn   = data.aws_iam_role.node.arn
  subnet_ids      = data.aws_subnets.private_by_az[each.value.az].ids
  instance_types  = [each.value.instance_type]
  ami_type        = "AL2023_ARM_64_STANDARD"
  disk_size       = 50

  scaling_config {
    desired_size = 1 # 每 AZ 一个 Keeper，构成跨 AZ 奇数 quorum
    min_size     = 1
    max_size     = 1 # quorum 成员数固定，不参与伸缩
  }

  labels = {
    workload   = "keeper"
    ck-cluster = each.value.cluster
  }

  taint {
    key    = "dedicated"
    value  = "keeper"
    effect = "NO_SCHEDULE"
  }

  tags = {
    "k8s.io/cluster-autoscaler/enabled"             = "true"
    "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
  }
}
```

- [ ] **Step 4: 验证语法与 for_each 展开**

Run: `terraform fmt -recursive && terraform -chdir=terraform validate`
Expected: `Success!`

- [ ] **Step 5: 提交**

```bash
git add terraform/nodegroups.tf
git commit -m "feat(tf): self-manage ClickHouse and Keeper node groups with for_each

Keys are per-(cluster, AZ) strings, so adding or removing a cluster only
touches that cluster's addresses. Carries over every attribute the upstream
module set, including the two autoscaler tags and the dedicated taint that
upstream added implicitly for clickhouse-prefixed pools."
```

---

## Task 4: 每集群 StorageClass

**Files:**
- Modify: `terraform/storage.tf`

- [ ] **Step 1: 替换为按集群 for_each 的 gp3 class**

把 `terraform/storage.tf` 中的 `kubernetes_storage_class.clickhouse_gp3` 与 `kubernetes_storage_class.clickhouse_ebs_comparison` 两个资源整块删除，替换为：

```hcl
# 每个 ebs 集群一个独立 gp3 class，因此各集群可用不同的 IOPS/吞吐档位。
# 默认 20k IOPS / 1250 MiB/s 来自实测：峰值 IOPS 14,993，而每次 I/O 120-157 KiB
# 意味着打满 1250 MiB/s 只需约 8,200 IOPS —— 该负载受吞吐限制而非 IOPS。
# 20k 也正好等于 r8g.4xlarge 的持续 EBS baseline（40k 是仅 30 分钟/24 小时的突发上限）。
# 吞吐不可下调：merge 窗口 p95 已达 1,130-1,193 MiB/s、设备利用率 102%。
resource "kubernetes_storage_class" "clickhouse_gp3" {
  for_each = local.ebs_clusters

  metadata {
    name = "ck-${each.key}-gp3"
  }

  storage_provisioner = "ebs.csi.aws.com"

  parameters = {
    encrypted  = "true"
    fsType     = "ext4"
    type       = "gp3"
    iops       = tostring(each.value.gp3_iops)
    throughput = tostring(each.value.gp3_throughput_mibps)
  }

  # Retain 而非 Delete：ebs profile 的全部价值就是卷比节点活得久。
  # Delete 会在 PVC 删除瞬间丢数据，正是这个 profile 要避免的本地盘失效模式。
  reclaim_policy = "Retain"
  # WaitForFirstConsumer 让卷在 Pod 被调度的 AZ 内绑定，与 AZ 绑定语义一致。
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
}
```

- [ ] **Step 2: 把 local-storage class 与 provisioner 改为条件创建**

在 `terraform/storage.tf` 中，把 `kubernetes_storage_class.local` 的 `count` 改为依赖新的 local:

```hcl
  count = local.has_local_nvme ? 1 : 0
```

同样把 `helm_release.local_static_provisioner` 的 `count` 改为：

```hcl
  count = local.has_local_nvme ? 1 : 0
```

- [ ] **Step 3: 新增 outputs 供 deploy.sh 读取**

在 `terraform/outputs.tf` 追加：

```hcl
output "clickhouse_cluster_names" {
  description = "已配置的 ClickHouse 集群 key 列表，供 deploy.sh 循环。"
  value       = keys(var.clickhouse_clusters)
}

output "clickhouse_cluster_config" {
  description = "每集群的渲染参数，供 deploy.sh 渲染 manifest 模板。"
  value = {
    for k, v in var.clickhouse_clusters : k => {
      storage_profile      = v.storage_profile
      storage_class        = v.storage_profile == "ebs" ? "ck-${k}-gp3" : "local-storage"
      shards               = v.shards
      replicas             = v.replicas
      zones                = v.zones
      data_volume_size_gib = v.data_volume_size_gib
      clickhouse_image     = v.clickhouse_image
      keeper_image         = v.keeper_image
      cpu_request          = v.cpu_request
      memory_request       = v.memory_request
      enable_backup        = v.enable_backup
      namespace            = "ck-${k}"
    }
  }
}
```

- [ ] **Step 4: 验证**

Run: `terraform fmt -recursive && terraform -chdir=terraform validate`
Expected: `Success!`

- [ ] **Step 5: 提交**

```bash
git add terraform/storage.tf terraform/outputs.tf
git commit -m "feat(tf): per-cluster StorageClass with independent gp3 tiers

Each ebs cluster gets its own class so tiers can differ per cluster. Uses
Retain rather than Delete: the point of this profile is that a volume outlives
its node, and Delete would discard data the moment a PVC is removed."
```

---

（后续 Task 5-11 见本文件第二部分，涵盖 manifest 模板化、deploy/teardown 改造与真实部署验证。）

## Task 5: Keeper manifest 模板化

**Files:**
- Create: `manifests/templates/10-keeper-chk.yaml.tmpl`
- Delete: `manifests/10-keeper-chk.yaml`

- [ ] **Step 1: 创建模板**

`manifests/10-keeper-chk.yaml` 复制为 `manifests/templates/10-keeper-chk.yaml.tmpl`，然后把以下四处改为占位符（其余内容保持不变）：

| 原值 | 改为 |
|---|---|
| `name: keeper` | `name: keeper-__CLUSTER__` |
| `namespace: clickhouse` | `namespace: __NAMESPACE__` |
| `image: "clickhouse/clickhouse-keeper:25.3"` | `image: "__KEEPER_IMAGE__"` |
| `nodeSelector:` 下的 `workload: keeper` | `workload: keeper` 后**新增一行** `ck-cluster: __CLUSTER__` |

新增的 `ck-cluster` nodeSelector 是必须的：没有它，一个集群的 Keeper Pod 可能被调度到另一个集群的 Keeper 节点上。

- [ ] **Step 2: 删除原静态 manifest**

```bash
git rm manifests/10-keeper-chk.yaml
```

- [ ] **Step 3: 验证模板占位符完整**

Run: `grep -c "__CLUSTER__\|__NAMESPACE__\|__KEEPER_IMAGE__" manifests/templates/10-keeper-chk.yaml.tmpl`
Expected: `4`（`__CLUSTER__` 出现两次，另两个各一次）

- [ ] **Step 4: 提交**

```bash
git add manifests/templates/10-keeper-chk.yaml.tmpl
git commit -m "refactor(k8s): template the Keeper manifest per cluster

Adds a ck-cluster nodeSelector so one cluster's Keeper cannot be scheduled
onto another cluster's Keeper nodes."
```

---

## Task 6: ClickHouse CHI manifest 模板化

**Files:**
- Create: `manifests/templates/20-clickhouse-chi.yaml.tmpl`
- Delete: `manifests/20-clickhouse-chi.yaml`

- [ ] **Step 1: 创建模板并替换占位符**

`manifests/20-clickhouse-chi.yaml` 复制为 `manifests/templates/20-clickhouse-chi.yaml.tmpl`，替换以下各处：

| 原值 | 改为 |
|---|---|
| `name: ch` | `name: __CLUSTER__` |
| `namespace: clickhouse`（metadata 处） | `namespace: __NAMESPACE__` |
| `host: keeper-keeper.clickhouse.svc.cluster.local` | `host: keeper-__CLUSTER__-keeper.__NAMESPACE__.svc.cluster.local` |
| `shardsCount: 1` | `shardsCount: __SHARDS__` |
| `replicasCount: 3` | `replicasCount: __REPLICAS__` |
| `image: "clickhouse/clickhouse-server:25.3"` | `image: "__CLICKHOUSE_IMAGE__"` |
| `cpu: "14"` | `cpu: "__CPU_REQUEST__"` |
| 两处 `memory: "110Gi"` | `memory: "__MEMORY_REQUEST__"` |
| `storageClassName: REPLACE_WITH_STORAGE_CLASS` | `storageClassName: __STORAGE_CLASS__` |
| `storage: 3400Gi` | `storage: __DATA_VOLUME_SIZE__Gi` |
| 两处 `clickhouse.altinity.com/chi: ch`（反亲和/spread 选择器） | `clickhouse.altinity.com/chi: __CLUSTER__` |
| `nodeSelector:` 下的 `workload: clickhouse` | `workload: clickhouse` 后**新增一行** `ck-cluster: __CLUSTER__` |

`admin/password_sha256_hex: "REPLACE_WITH_ADMIN_SHA256"` **保持不变** —— deploy.sh 已有替换逻辑。

- [ ] **Step 2: 新增 ZooKeeper path 前缀隔离**

在模板的 `configuration.zookeeper` 块中，`nodes` 之后追加一行，使各集群的 Keeper 数据互不干扰：

```yaml
      root: /clickhouse/__CLUSTER__
```

- [ ] **Step 3: 删除原静态 manifest**

```bash
git rm manifests/20-clickhouse-chi.yaml
```

- [ ] **Step 4: 验证无遗漏的硬编码值**

Run: `grep -nE "clickhouse-ch|namespace: clickhouse|shardsCount: 1|replicasCount: 3|3400Gi|\"14\"|110Gi" manifests/templates/20-clickhouse-chi.yaml.tmpl`
Expected: 无输出（全部已参数化）

- [ ] **Step 5: 提交**

```bash
git add manifests/templates/20-clickhouse-chi.yaml.tmpl
git commit -m "refactor(k8s): template the CHI per cluster

Parameterizes topology, storage class, volume size, image, and resources.
Adds a per-cluster ZooKeeper root so clusters sharing no Keeper still cannot
collide on coordination paths, plus a ck-cluster nodeSelector so pods land on
their own cluster's node pool."
```

---

## Task 7: 备份 manifest 模板化

**Files:**
- Create: `manifests/templates/30-backup-cronjob.yaml.tmpl`
- Delete: `manifests/30-backup-cronjob.yaml`
- Modify: `terraform/irsa.tf`

- [ ] **Step 1: 创建模板**

`manifests/30-backup-cronjob.yaml` 复制为 `manifests/templates/30-backup-cronjob.yaml.tmpl`，把全部三处 `namespace: clickhouse` 改为 `namespace: __NAMESPACE__`，并把 S3 路径加上集群前缀，使各集群备份互不覆盖：

| 原值 | 改为 |
|---|---|
| `S3_BUCKET: "REPLACE_WITH_BUCKET"` | 保持不变 |
| （新增）在 `S3_BUCKET` 下方 | `S3_PATH: "__CLUSTER__"` |

- [ ] **Step 2: IRSA 改为每集群一个 role**

把 `terraform/irsa.tf` 中 `aws_iam_role.backup` 及其 policy 改为 `for_each`：

```hcl
resource "aws_iam_role" "backup" {
  for_each = { for k, v in var.clickhouse_clusters : k => v if v.enable_backup }

  name               = "${var.cluster_name}-ck-${each.key}-backup"
  assume_role_policy = data.aws_iam_policy_document.backup_assume[each.key].json
}
```

对应的 `data.aws_iam_policy_document.backup_assume` 也改为 `for_each`，并把 subject 改为按集群 namespace：

```hcl
      values = ["system:serviceaccount:ck-${each.key}:clickhouse-backup"]
```

`aws_iam_role_policy.backup_s3` 同样改为 `for_each`，并把 S3 资源限定到集群前缀：

```hcl
      Resource = ["${aws_s3_bucket.backup.arn}/${each.key}/*"]
```

- [ ] **Step 3: 新增 output 供 deploy.sh 读取每集群 role ARN**

在 `terraform/outputs.tf` 追加：

```hcl
output "backup_role_arns" {
  description = "每集群的备份 IRSA role ARN，供 deploy.sh 渲染 ServiceAccount 注解。"
  value       = { for k, r in aws_iam_role.backup : k => r.arn }
}
```

并删除原来的单值 `backup_role_arn` output。

- [ ] **Step 4: 删除原静态 manifest 并验证**

```bash
git rm manifests/30-backup-cronjob.yaml
terraform fmt -recursive && terraform -chdir=terraform validate
```
Expected: `Success!`

- [ ] **Step 5: 提交**

```bash
git add manifests/templates/30-backup-cronjob.yaml.tmpl terraform/irsa.tf terraform/outputs.tf
git commit -m "refactor(k8s): per-cluster backup namespace, S3 prefix, and IRSA role

Each cluster gets its own IAM role scoped to its own S3 prefix, so one
cluster's backup credentials cannot read or overwrite another's."
```

---

## Task 8: deploy.sh 按集群循环

**Files:**
- Modify: `scripts/deploy.sh`

- [ ] **Step 1: 新增渲染函数**

在 `scripts/deploy.sh` 的两阶段 `terraform apply` 之后、原来读取单值 output 的位置，替换为读取 map：

```bash
cd terraform
BUCKET=$(terraform output -raw backup_bucket)
REGION=$(terraform output -raw region)
[ -n "$REGION" ] || { echo "ERROR: could not read region from terraform output" >&2; exit 1; }
CLUSTERS=$(terraform output -json clickhouse_cluster_names | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin)))')
CLUSTER_CFG=$(terraform output -json clickhouse_cluster_config)
BACKUP_ROLES=$(terraform output -json backup_role_arns)
eval "$(terraform output -raw configure_kubectl)"
cd ..

[ -n "$CLUSTERS" ] || { echo "ERROR: clickhouse_clusters is empty; nothing to deploy." >&2; exit 1; }
echo "==> clusters to deploy: $CLUSTERS"

# 从 JSON 取单个字段，避免在 bash 里手写 JSON 解析。
cfg() { printf '%s' "$CLUSTER_CFG" | python3 -c "import json,sys; print(json.load(sys.stdin)['$1']['$2'])"; }

render() {
  local tmpl=$1 out=$2 cluster=$3
  sed \
    -e "s|__CLUSTER__|$cluster|g" \
    -e "s|__NAMESPACE__|$(cfg "$cluster" namespace)|g" \
    -e "s|__SHARDS__|$(cfg "$cluster" shards)|g" \
    -e "s|__REPLICAS__|$(cfg "$cluster" replicas)|g" \
    -e "s|__STORAGE_CLASS__|$(cfg "$cluster" storage_class)|g" \
    -e "s|__DATA_VOLUME_SIZE__|$(cfg "$cluster" data_volume_size_gib)|g" \
    -e "s|__CLICKHOUSE_IMAGE__|$(cfg "$cluster" clickhouse_image)|g" \
    -e "s|__KEEPER_IMAGE__|$(cfg "$cluster" keeper_image)|g" \
    -e "s|__CPU_REQUEST__|$(cfg "$cluster" cpu_request)|g" \
    -e "s|__MEMORY_REQUEST__|$(cfg "$cluster" memory_request)|g" \
    "$tmpl" >"$out"
}
```

- [ ] **Step 2: 新增前置校验函数**

紧接上一步追加。这七项校验对应的都是实测遇到过的故障模式：

```bash
preflight() {
  local cluster=$1
  local sc profile ns want_nodes have_nodes binding
  sc=$(cfg "$cluster" storage_class)
  profile=$(cfg "$cluster" storage_profile)
  ns=$(cfg "$cluster" namespace)
  want_nodes=$(cfg "$cluster" replicas)

  # 1. StorageClass 存在 —— 缺失会让 PVC 永久 Pending 且无明显报错
  kubectl get storageclass "$sc" >/dev/null 2>&1 \
    || { echo "ERROR[$cluster]: StorageClass '$sc' not found; Terraform should have created it." >&2; return 1; }

  # 2. WaitForFirstConsumer —— AZ 绑定卷必须在 Pod 落地的 AZ 内绑定
  binding=$(kubectl get storageclass "$sc" -o jsonpath='{.volumeBindingMode}')
  [ "$binding" = "WaitForFirstConsumer" ] \
    || { echo "ERROR[$cluster]: StorageClass '$sc' has volumeBindingMode=$binding; need WaitForFirstConsumer." >&2; return 1; }

  # 3. 数据节点数量足够 —— 否则 Pod Pending 且原因隐晦
  have_nodes=$(kubectl get nodes -l "workload=clickhouse,ck-cluster=$cluster" --no-headers 2>/dev/null | grep -c " Ready" || true)
  [ "$have_nodes" -ge "$want_nodes" ] \
    || { echo "ERROR[$cluster]: only $have_nodes Ready data nodes, need $want_nodes." >&2; return 1; }

  # 4. Keeper 节点就绪
  have_nodes=$(kubectl get nodes -l "workload=keeper,ck-cluster=$cluster" --no-headers 2>/dev/null | grep -c " Ready" || true)
  [ "$have_nodes" -ge 3 ] \
    || { echo "ERROR[$cluster]: only $have_nodes Ready Keeper nodes, need 3." >&2; return 1; }

  # 5. 存储介质专属检查
  if [ "$profile" = "local-nvme" ]; then
    kubectl -n kube-system get daemonset nvme-bootstrap >/dev/null 2>&1 \
      || { echo "ERROR[$cluster]: nvme-bootstrap DaemonSet missing; PVCs would stay Pending." >&2; return 1; }
  else
    kubectl -n kube-system get daemonset ebs-csi-node >/dev/null 2>&1 \
      || { echo "ERROR[$cluster]: ebs-csi-node DaemonSet missing; gp3 volumes cannot be provisioned." >&2; return 1; }
  fi

  echo "    preflight[$cluster] OK (storage=$sc profile=$profile ns=$ns)"
}
```

- [ ] **Step 3: 替换部署主体为按集群循环**

把 `deploy.sh` 中原先「渲染 manifest → apply namespace/backup/CHK/CHI」的整段替换为：

```bash
ADMIN_SHA=$(printf '%s' "$CLICKHOUSE_ADMIN_PASSWORD" | sha256sum | awk '{print $1}')
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

for cluster in $CLUSTERS; do
  ns=$(cfg "$cluster" namespace)
  echo "==> deploying cluster '$cluster' into namespace '$ns'"

  preflight "$cluster" || exit 1

  render manifests/templates/10-keeper-chk.yaml.tmpl "$tmpdir/chk-$cluster.yaml" "$cluster"
  render manifests/templates/20-clickhouse-chi.yaml.tmpl "$tmpdir/chi-$cluster.yaml" "$cluster"
  sed -i.bak "s|REPLACE_WITH_ADMIN_SHA256|$ADMIN_SHA|g" "$tmpdir/chi-$cluster.yaml"

  if [ "$(cfg "$cluster" enable_backup)" = "True" ]; then
    role_arn=$(printf '%s' "$BACKUP_ROLES" | python3 -c "import json,sys; print(json.load(sys.stdin)['$cluster'])")
    render manifests/templates/30-backup-cronjob.yaml.tmpl "$tmpdir/backup-$cluster.yaml" "$cluster"
    sed -i.bak \
      -e "s|REPLACE_WITH_BACKUP_ROLE_ARN|$role_arn|g" \
      -e "s|REPLACE_WITH_BUCKET|$BUCKET|g" \
      -e "s|S3_REGION: \"us-east-1\"|S3_REGION: \"$REGION\"|g" \
      "$tmpdir/backup-$cluster.yaml"
  fi

  # 6. 占位符残留检查 —— 未替换的占位符会让认证或备份静默失效
  if grep -rq "REPLACE_WITH\|__[A-Z_]*__" "$tmpdir"/*-"$cluster".yaml; then
    echo "ERROR[$cluster]: unsubstituted placeholder remains in rendered manifests" >&2
    grep -rn "REPLACE_WITH\|__[A-Z_]*__" "$tmpdir"/*-"$cluster".yaml >&2
    exit 1
  fi

  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
  [ -f "$tmpdir/backup-$cluster.yaml" ] && kubectl apply -f "$tmpdir/backup-$cluster.yaml"
  kubectl apply -f "$tmpdir/chk-$cluster.yaml"

  # 7. Keeper quorum 就绪 —— CHI 在 Keeper 未就绪时会反复重启
  echo "    waiting for Keeper quorum"
  kubectl -n "$ns" wait --for=condition=Ready pod -l app=clickhouse-keeper --timeout=600s \
    || { echo "ERROR[$cluster]: Keeper did not reach Ready; refusing to apply the CHI." >&2; exit 1; }

  kubectl apply -f "$tmpdir/chi-$cluster.yaml"
  echo "    waiting for ClickHouse pods"
  kubectl -n "$ns" wait --for=condition=Ready pod -l clickhouse.altinity.com/chi="$cluster" --timeout=900s \
    || echo "WARNING[$cluster]: pods not all Ready within timeout; check kubectl -n $ns get pods" >&2

  CLICKHOUSE_NAMESPACE="$ns" CLICKHOUSE_CLUSTER="$cluster" ./scripts/smoke-test.sh \
    || { echo "ERROR[$cluster]: smoke test failed." >&2; exit 1; }

  echo "==> cluster '$cluster' ready"
done

kubectl apply -f manifests/40-grafana-dashboard.yaml
echo "==> all clusters deployed: $CLUSTERS"
```

注意 `enable_backup` 的比较值是 `True`（首字母大写）—— Python 的 `json.load` 把 JSON `true` 打印为 `True`。

- [ ] **Step 4: 验证脚本语法**

Run: `bash -n scripts/deploy.sh && shellcheck scripts/deploy.sh`
Expected: 无输出（shellcheck 干净）

- [ ] **Step 5: 提交**

```bash
git add scripts/deploy.sh
git commit -m "feat(deploy): loop over clusters with per-cluster preflight checks

Seven preflight checks run before each CHI is applied. Each one corresponds to
a failure mode hit during earlier work: a missing StorageClass or wrong binding
mode leaves PVCs Pending with no clear cause, insufficient nodes leaves pods
Pending obscurely, a leftover placeholder breaks auth or backup silently, and
applying a CHI before Keeper has quorum makes it restart repeatedly."
```

---

## Task 9: smoke-test.sh 参数化

**Files:**
- Modify: `scripts/smoke-test.sh`

- [ ] **Step 1: 接受 namespace 与集群名**

在 `scripts/smoke-test.sh` 顶部（`set -euo pipefail` 之后）插入：

```bash
NS=${CLICKHOUSE_NAMESPACE:-clickhouse}
CH_CLUSTER=${CLICKHOUSE_CLUSTER:-main}
# CHI 内部的逻辑 cluster 名固定为 main；CH_CLUSTER 是 CHI 资源名，用于定位 Pod。
LOGICAL_CLUSTER=main
```

- [ ] **Step 2: 把硬编码的 namespace 与 cluster 名替换为变量**

把脚本中所有 `-n clickhouse` 改为 `-n "$NS"`，把 `WHERE cluster='main'` 改为 `WHERE cluster='$LOGICAL_CLUSTER'`，并把定位 Pod 的选择器改为按 CHI 名：

```bash
POD=$(kubectl -n "$NS" get pods -l clickhouse.altinity.com/chi="$CH_CLUSTER" -o name | head -1)
[ -n "$POD" ] || { echo "ERROR: no ClickHouse pod found in $NS for CHI $CH_CLUSTER" >&2; exit 1; }
```

- [ ] **Step 3: 新增拓扑断言**

在脚本末尾、原有的分布式计数校验之后追加。这一步验证实际拓扑与期望一致，防止模板渲染错误被忽略：

```bash
if [ -n "${EXPECTED_REPLICAS:-}" ]; then
  ACTUAL=$(run "SELECT count() FROM system.clusters WHERE cluster='$LOGICAL_CLUSTER'" | tr -d '[:space:]')
  if [ "$ACTUAL" != "$EXPECTED_REPLICAS" ]; then
    echo "==> SMOKE TEST FAILED (system.clusters has $ACTUAL entries, expected $EXPECTED_REPLICAS)" >&2
    exit 1
  fi
  echo "==> topology verified: $ACTUAL cluster entries"
fi
```

- [ ] **Step 4: 验证**

Run: `bash -n scripts/smoke-test.sh && shellcheck scripts/smoke-test.sh`
Expected: 无输出

- [ ] **Step 5: 提交**

```bash
git add scripts/smoke-test.sh
git commit -m "feat(test): parameterize smoke test by namespace and CHI name

Adds an optional topology assertion so a template rendering error that produces
the wrong shard or replica count fails the deploy instead of passing silently."
```

---

## Task 10: teardown 支持单集群且不依赖 Kubernetes API

三次失败的 destroy 直接决定了这个任务的设计：必须可重入，且 AWS 资源销毁不能被 in-cluster 资源阻塞。

**Files:**
- Modify: `scripts/teardown.sh`

- [ ] **Step 1: 新增 --cluster 参数解析**

在 `scripts/teardown.sh` 的 `cd "$(dirname "$0")/.."` 之后插入：

```bash
ONLY_CLUSTER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --cluster)
      ONLY_CLUSTER=${2:?--cluster requires a name}
      shift 2
      ;;
    *)
      echo "usage: $0 [--cluster <name>]" >&2
      exit 64
      ;;
  esac
done
```

- [ ] **Step 2: 新增集群内资源清理函数**

紧接上一步追加。顺序是关键：先删 CHI 让 EBS CSI 在集群还活着时回收卷，否则 `DeleteOnTermination=False` 的卷会在控制面消失后永久留存：

```bash
# 按实际存在的资源删除，而不是按 manifest 文件名 —— 旧版脚本硬编码了文件里的资源名
# （ch），对实际存在的 ch-ebs / ch-local 视而不见，导致 PVC 在 CHI 仍存活时被删。
delete_cluster_in_k8s() {
  local ns=$1
  kubectl get namespace "$ns" >/dev/null 2>&1 || { echo "    namespace $ns absent, skipping"; return 0; }

  # Capture volume IDs first: after the PV objects are gone they are unfindable.
  local vol_ids
  vol_ids=$(collect_volume_ids "$ns")

  echo "    deleting CHI in $ns (lets the operator and CSI driver release volumes)"
  kubectl -n "$ns" delete chi --all --ignore-not-found --timeout=600s || true
  # 等 Pod 真正退出，卷才会被 detach
  kubectl -n "$ns" wait --for=delete pod -l clickhouse.altinity.com/app=chop --timeout=600s 2>/dev/null || true

  echo "    deleting Keeper in $ns"
  kubectl -n "$ns" delete chk --all --ignore-not-found --timeout=300s || true

  echo "    deleting remaining PVCs in $ns"
  kubectl -n "$ns" delete pvc --all --ignore-not-found --timeout=300s || true

  echo "    deleting namespace $ns"
  kubectl delete namespace "$ns" --ignore-not-found --timeout=300s || true

  # Retain means these are still billed until explicitly deleted.
  delete_volumes "$ns" "$vol_ids"
}

# 在拆控制面之前确认卷已回收。控制面一消失，CSI 驱动随之消失，就再也没有东西
# 能执行删卷动作，卷会永久留在账单上。
# reclaim_policy on the gp3 classes is Retain, so deleting a PVC leaves the PV and
# the underlying EBS volume in place, still billed. Nothing else reclaims them:
# the volumes are created by the CSI driver, not Terraform, so they are absent
# from state and survive `terraform destroy` and even the EKS cluster itself.
# The default config is 3 x 3400 GiB, so leaking them costs well over $1,000 a
# month for volumes attached to nothing.
#
# The volume IDs must be read BEFORE the namespace and PV objects are deleted --
# afterwards the only way to find them is a tag sweep, which is kept below as a
# fallback rather than the primary path.
collect_volume_ids() {
  local ns=$1
  kubectl get pv -o json 2>/dev/null | python3 -c '
import json,sys
ns=sys.argv[1]
for pv in json.load(sys.stdin).get("items",[]):
    ref=(pv.get("spec",{}).get("claimRef") or {})
    if ref.get("namespace")!=ns: continue
    h=(pv.get("spec",{}).get("csi") or {}).get("volumeHandle")
    if h and h.startswith("vol-"): print(h)
' "$ns"
}

delete_volumes() {
  local ns=$1 ids=$2 region=${AWS_REGION:-us-east-1} v
  for v in $ids; do
    echo "    deleting EBS volume $v (Retain left it behind)"
    # A volume still attaching needs a moment; retry briefly rather than leaking it.
    for _ in 1 2 3 4 5 6; do
      aws ec2 delete-volume --volume-id "$v" --region "$region" 2>/dev/null && break
      sleep 10
    done
  done

  # Belt and braces: catch anything whose PV object was already gone.
  local swept
  swept=$(aws ec2 describe-volumes --region "$region" \
    --filters "Name=tag:kubernetes.io/created-for/pvc/namespace,Values=$ns" "Name=status,Values=available" \
    --query 'Volumes[].VolumeId' --output text 2>/dev/null | tr '\t' '\n' | grep -c . || true)
  if [ "${swept:-0}" -gt 0 ]; then
    echo "    tag sweep found $swept additional volume(s) for $ns"
    aws ec2 describe-volumes --region "$region" \
      --filters "Name=tag:kubernetes.io/created-for/pvc/namespace,Values=$ns" "Name=status,Values=available" \
      --query 'Volumes[].VolumeId' --output text | tr '\t' '\n' | while read -r v; do
      [ -n "$v" ] && aws ec2 delete-volume --volume-id "$v" --region "$region" 2>/dev/null || true
    done
  fi
}

verify_volumes_released() {
  local ns=$1 left
  left=$(aws ec2 describe-volumes --region "${AWS_REGION:-us-east-1}" \
    --filters "Name=tag:kubernetes.io/created-for/pvc/namespace,Values=$ns" \
    --query 'Volumes[].VolumeId' --output text 2>/dev/null | tr '\t' '\n' | grep -c . || true)
  if [ "$left" -gt 0 ]; then
    echo "WARNING: $left EBS volume(s) still tagged for namespace $ns." >&2
    echo "         They will NOT be reclaimed once the control plane is gone." >&2
    aws ec2 describe-volumes --region "${AWS_REGION:-us-east-1}" \
      --filters "Name=tag:kubernetes.io/created-for/pvc/namespace,Values=$ns" \
      --query 'Volumes[].[VolumeId,Size,State]' --output text >&2
    return 1
  fi
  echo "    all volumes for $ns released"
}
```

- [ ] **Step 3: 单集群路径**

追加。单集群销毁只动该集群的 Terraform 地址，其他集群不受影响：

```bash
if [ -n "$ONLY_CLUSTER" ]; then
  ns="ck-$ONLY_CLUSTER"
  echo "==> tearing down only cluster '$ONLY_CLUSTER' (namespace $ns)"
  delete_cluster_in_k8s "$ns"
  verify_volumes_released "$ns" || echo "WARNING: continuing despite unreleased volumes" >&2

  echo "==> removing this cluster's Terraform resources"
  targets=()
  while IFS= read -r addr; do
    targets+=(-target="$addr")
  done < <(terraform -chdir=terraform state list 2>/dev/null \
    | grep -E "^(aws_eks_node_group\.(clickhouse|keeper)|kubernetes_storage_class\.clickhouse_gp3|aws_iam_role\.backup|aws_iam_role_policy\.backup_s3)\[\"$ONLY_CLUSTER" )

  if [ ${#targets[@]} -eq 0 ]; then
    echo "    no Terraform resources found for '$ONLY_CLUSTER'"
  else
    terraform -chdir=terraform destroy -auto-approve "${targets[@]}"
  fi
  echo "==> cluster '$ONLY_CLUSTER' torn down. Remove it from clickhouse_clusters in tfvars to keep state and config in sync."
  exit 0
fi
```

- [ ] **Step 4: 全量路径改为可重入且不依赖 Kubernetes API**

把原有的全量销毁逻辑替换为：

```bash
echo "==> full teardown: all clusters"
for ns in $(kubectl get namespace -o name 2>/dev/null | sed 's|namespace/||' | grep '^ck-' || true); do
  delete_cluster_in_k8s "$ns"
  verify_volumes_released "$ns" || echo "WARNING: continuing despite unreleased volumes in $ns" >&2
done

cd terraform
BACKUP_BUCKET=$(terraform output -raw backup_bucket 2>/dev/null || echo "")

# 保留备份桶：先移出 state，否则 destroy 会因桶非空而失败，或删掉桶的安全配置。
if [ -n "$BACKUP_BUCKET" ]; then
  echo "==> retaining S3 backup bucket outside Terraform state: $BACKUP_BUCKET"
  for address in \
    aws_s3_bucket_public_access_block.backup \
    aws_s3_bucket_server_side_encryption_configuration.backup \
    aws_s3_bucket_versioning.backup \
    aws_s3_bucket.backup; do
    terraform state rm "$address" 2>/dev/null || true
  done
fi

# 关键：先把所有需要 Kubernetes API 的资源移出 state。它们没有独立的 AWS 计费，
# 且会随集群一起消失；留着它们会让 destroy 在 tunnel 断开时卡死数分钟后失败
# （实测三次 destroy 有两次因此中断）。
echo "==> removing in-cluster resources from state so destroy needs only the AWS API"
while IFS= read -r addr; do
  echo "    state rm $addr"
  terraform state rm "$addr" >/dev/null 2>&1 || true
done < <(terraform state list 2>/dev/null | grep -E "helm_release|kubernetes_")

# destroy 可重入：网络或 DNS 中断后重跑即可继续。
echo "==> terraform destroy (retries once on transient failure)"
terraform destroy -auto-approve || {
  echo "WARNING: destroy did not complete; retrying once" >&2
  terraform destroy -auto-approve
}
cd ..

echo "==> teardown complete."
[ -n "$BACKUP_BUCKET" ] && echo "    retained bucket: $BACKUP_BUCKET (delete object versions manually if no longer needed)"
```

- [ ] **Step 5: 验证**

Run: `bash -n scripts/teardown.sh && shellcheck scripts/teardown.sh`
Expected: 无输出

- [ ] **Step 6: 提交**

```bash
git add scripts/teardown.sh
git commit -m "feat(teardown): per-cluster granularity, re-entrant, no Kubernetes API dependency

Three lessons from failed destroys are encoded here. Deleting the CHI first
lets the CSI driver reclaim volumes while the control plane still exists;
DeleteOnTermination is False on data volumes, so a volume left attached when
the control plane goes away is billed forever with nothing left to reclaim it.
In-cluster resources are removed from state before destroy so a dropped tunnel
cannot stall it. And destroy retries once, because a transient DNS failure
interrupted a run whose delete requests had already taken effect.

Also fixes the original bug: the script deleted by manifest filename, so it
looked for a CHI named ch and silently skipped the ch-ebs and ch-local that
actually existed, deleting PVCs while their pods still held them."
```

---

## Task 11: 真实部署验证

这是本计划的验收关口。「能真正拉起集群」是设计确认时的前提条件，因此必须实际部署，而不是只跑静态检查。

**Files:**
- Modify: `terraform/terraform.tfvars`（本地文件，已 gitignore）

- [ ] **Step 1: 静态校验全绿**

```bash
terraform fmt -check -recursive
terraform -chdir=terraform validate
bash -n scripts/deploy.sh scripts/teardown.sh scripts/smoke-test.sh
shellcheck scripts/deploy.sh scripts/teardown.sh scripts/smoke-test.sh
./scripts/check-docs.sh
```
Expected: 全部通过，无输出或 `Success!`

- [ ] **Step 2: 从零拉起默认的 ebs 集群**

确认 `terraform/terraform.tfvars` 中不含 `clickhouse_clusters`（使用默认值：仅 `ebs`），然后：

```bash
CLICKHOUSE_ADMIN_PASSWORD='<strong-secret>' AUTO_APPROVE=true ./scripts/deploy.sh 2>&1 | tee /tmp/deploy-ebs.log
```
Expected: 结尾出现 `==> all clusters deployed: ebs`，且中途出现 `preflight[ebs] OK` 与 `SMOKE TEST PASSED`。

- [ ] **Step 3: 核实实际拓扑与节点组命名**

```bash
kubectl -n ck-ebs get chi,chk,pods
kubectl get nodes -L ck-cluster,workload,storage
aws eks list-nodegroups --cluster-name clickhouse-eks --region us-east-1 --output json
```
Expected: `ck-ebs` 里 3 个 ClickHouse Pod 与 3 个 Keeper Pod 全部 Running；节点组名为 `ck-ebs-us-east-1a`、`kp-ebs-us-east-1a` 等形式（**不含** `node-group-N`）。

- [ ] **Step 4: 追加第二个正式规格集群**

在 `terraform/terraform.tfvars` 中写入：

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

- [ ] **Step 5: 验证 plan 在 ebs-* 地址零变更（核心验收标准）**

```bash
terraform -chdir=terraform plan -lock=false -out=/tmp/add-nvme.plan 2>&1 | tee /tmp/plan-add.log
sed 's/\x1b\[[0-9;]*m//g' /tmp/plan-add.log | grep -E '^  # ' | grep '"ebs' || echo "ZERO CHANGES ON ebs-* — PASS"
```
Expected: 输出 `ZERO CHANGES ON ebs-* — PASS`。若任何 `ebs-*` 地址出现在变更列表中，说明隔离性未达成，必须停下修复而不是继续。

- [ ] **Step 6: apply 并验证两集群同时健康**

```bash
CLICKHOUSE_ADMIN_PASSWORD='<strong-secret>' AUTO_APPROVE=true ./scripts/deploy.sh 2>&1 | tee /tmp/deploy-both.log
kubectl -n ck-ebs get pods --no-headers | grep -c Running
kubectl -n ck-nvme get pods --no-headers | grep -c Running
```
Expected: 两个 namespace 各 6 个 Pod Running（3 ClickHouse + 3 Keeper），且 `ck-ebs` 的 Pod 未重启（`RESTARTS` 为 0，证明追加集群没有干扰它）。

- [ ] **Step 7: 验证 autoscaler 识别与 taint 生效**

```bash
kubectl -n kube-system logs -l app.kubernetes.io/name=aws-cluster-autoscaler --tail=50 | grep -iE "ck-ebs|ck-nvme|node group"
kubectl run taint-probe --image=busybox --restart=Never --command -- sleep 60
sleep 20 && kubectl get pod taint-probe -o wide
kubectl delete pod taint-probe --ignore-not-found
```
Expected: autoscaler 日志中出现自管节点组（证明两个 tag 生效）；`taint-probe` **不会**落在任何 `workload=clickhouse` 或 `workload=keeper` 节点上（证明 taint 生效）。

- [ ] **Step 8: 删除第二个集群并验证零变更**

```bash
./scripts/teardown.sh --cluster nvme 2>&1 | tee /tmp/teardown-nvme.log
```

然后把 `nvme` 从 `terraform.tfvars` 的 map 中删除，再：

```bash
terraform -chdir=terraform plan -lock=false 2>&1 | tee /tmp/plan-after-rm.log
sed 's/\x1b\[[0-9;]*m//g' /tmp/plan-after-rm.log | grep -E '^  # ' | grep '"ebs' || echo "ZERO CHANGES ON ebs-* — PASS"
```
Expected: 再次输出 `ZERO CHANGES ON ebs-* — PASS`，且 `kubectl -n ck-ebs get pods` 显示 Pod 仍 Running、`RESTARTS` 为 0。

- [ ] **Step 9: 记录验证结果**

把验证证据写入 `results/multi-cluster-verify/<UTC 时间戳>/`：`deploy-ebs.log`、`plan-add.log`、`deploy-both.log`、`teardown-nvme.log`、`plan-after-rm.log`，以及 `kubectl get nodes -L ck-cluster` 与两次 plan 的摘要。该目录已被 gitignore，只在报告中引用结论。

- [ ] **Step 10: 提交验证结论**

```bash
git add -A docs
git commit -m "docs: record multi-cluster isolation verification results

Adding and removing a cluster both produced zero plan changes on the existing
cluster's addresses, and its pods never restarted. Node groups are named
ck-<cluster>-<az> rather than index-derived node-group-N, so the upstream
shifting problem is structurally gone."
```

---

## 自查

**规格覆盖：** 设计文档 3.1（集群标识派生）→ Task 1；3.2（节点组接管）→ Task 2、3；3.3（外部依赖）→ Task 3 Step 1；3.4（属性照抄）→ Task 3 Step 2、3；3.5（模板渲染）→ Task 5、6、7；4.1（部署流程）→ Task 8；4.2（前置校验）→ Task 8 Step 2；4.3（单集群销毁）→ Task 10；4.4（迁移路径）→ 前置状态已完成；第 5 节（验证计划）→ Task 11。每一节都有对应任务。

**已知取舍：** 本计划不实现集群间共享 Keeper（设计已明确每集群独立）、不实现 Karpenter、不改变湖仓为 SoT 的前提。

**遗留 TODO（不在本计划范围）：** 本地 NVMe profile 的 HA 演练需对称跨 AZ 拓扑；带写入负载的 P8；gp3 降档后的性能中性验证尚未实测，不得与降档前数字直接相减。
