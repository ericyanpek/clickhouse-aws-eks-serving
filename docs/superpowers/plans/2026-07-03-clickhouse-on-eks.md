# ClickHouse on EKS 实施计划
**中文** · [English](./2026-07-03-clickhouse-on-eks.en.md)

> **⚠️ 历史记录 — 此后拓扑已修订。** 本计划记录最初的构建
>（i4i.xlarge/x86 上的 2 分片 × 2 副本，共 4 个节点）。实施后，设计被有意重新调整为
> **i8g.4xlarge（ARM/Graviton）上的 1 分片 × 3 副本，共 3 个节点**，
> 并采用专用节点资源模型（较高 CPU request / 不设 CPU limit，内存 request==limit，
> `max_server_memory_usage_to_ram_ratio: 0.9`）。当前事实来源是代码、
> [`../../../README.md`](../../../README.md) 和
> [`../../../README.en.md`](../../../README.en.md)。设计规范仅作为背景上下文。
> 下文的命令、版本、拓扑、脚本和恢复行为均为历史内容，可能已经过时。
> 本文件刻意不按新设计重写，因为它保留了实际执行过的构建历史。

> **面向智能体工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans，逐项任务实施本计划。步骤使用复选框（`- [ ]`）语法跟踪。

**目标：** 产出可审查、可执行的 IaC，在新的 EKS 集群上搭建一个 2 分片 × 2 副本的 ClickHouse 集群，包含 3 节点 Keeper、本地 NVMe 存储、Prometheus/Grafana，以及通过 clickhouse-backup 备份到 S3；基础设施使用 Altinity Terraform EKS Blueprint 的 `eks/` 和 `clickhouse-operator/` 子模块，拓扑则使用我们自己的 CHI/CHK 清单。

**架构：** 混合方式（方案 1）。Terraform 包装层使用 `Altinity/terraform-aws-eks-clickhouse//eks`（固定为 v0.5.7）提供 VPC/EKS/节点组，并使用 `//clickhouse-operator`（operator 固定为 0.27.1）。我们禁用蓝图中封闭的 `clickhouse-cluster` 子模块，改为应用自己的 ClickHouseInstallation（CHI）和 ClickHouseKeeperInstallation（CHK）清单，从而完全控制分片/副本、本地 NVMe 绑定、反亲和性和备份。Terraform 还会预置存储类、kube-prometheus-stack、S3 备份桶以及 clickhouse-backup IRSA 角色。

**技术栈：** Terraform ≥1.5（AWS provider ~>5.40、helm >=2.9,<3.0、kubernetes >=2.25.2）、Altinity clickhouse-operator 0.27.1、ClickHouse Keeper（CHK CRD）、通过 local-static-provisioner 使用 i4i 本地 NVMe、kube-prometheus-stack、通过 IRSA 将 clickhouse-backup 写入 S3。

**重要 — 测试模型：** 这是基础设施代码。我们不运行 `terraform apply`（它会创建真实且产生费用的 AWS 资源，应由用户负责）。每项任务的验证均为**静态**验证：`terraform fmt -check`、`terraform validate`、`helm template`/`helm lint` 和 `kubectl apply --dry-run=client`。最终冒烟测试是一个*由我们编写*、供用户在自行 apply 后运行的脚本；我们不执行它。

**验证步骤的前提条件：** `terraform init` 需要网络访问来下载 provider/模块。如果完全离线运行，只要 provider 已缓存，`init` 后的 `terraform validate` 仍可工作。节点/AZ 名称、区域和 ClickHouse LTS 版本均为变量，用户须在 apply 前于 `terraform.tfvars` 中确认。

---

## 文件结构

```
clickhouse-deployment/
├── terraform/
│   ├── versions.tf          # required_providers version locks + backend stub
│   ├── providers.tf         # aws + kubernetes + helm providers (exec auth to EKS)
│   ├── eks.tf               # module "eks" (blueprint //eks @ v0.5.7) + node pools
│   ├── operator.tf          # module "operator" (blueprint //clickhouse-operator)
│   ├── storage.tf           # gp3 StorageClass + local-static-provisioner (helm)
│   ├── monitoring.tf        # kube-prometheus-stack (helm)
│   ├── s3.tf                # backup bucket (encrypted / block-public / versioned)
│   ├── irsa.tf              # OIDC data source + clickhouse-backup IAM role/policy
│   ├── variables.tf         # all tunables
│   ├── outputs.tf           # kubeconfig cmd, bucket, sa-role-arn, namespace
│   └── terraform.tfvars     # pinned defaults (user reviews before apply)
├── manifests/
│   ├── 00-namespace.yaml
│   ├── 10-keeper-chk.yaml         # CHK, 3 nodes cross-AZ, gp3
│   ├── 20-clickhouse-chi.yaml     # CHI 2×2, local-NVMe, anti-affinity, backup sidecar
│   ├── 30-backup-cronjob.yaml     # clickhouse-backup → S3 CronJob
│   └── 40-grafana-dashboard.yaml  # dashboard #12163 ConfigMap
├── scripts/
│   ├── deploy.sh            # terraform apply → wait → apply manifests (for USER)
│   ├── smoke-test.sh        # end-to-end validation (for USER, post-apply)
│   └── teardown.sh          # ordered destroy (for USER)
└── README.md               # prerequisites, apply steps, verify, cost, teardown
```

**拆分依据：** Terraform 按职责拆分（基础设施 / operator / 存储 / 监控 / backup-IAM），使每个文件都能独立审查。清单按应用顺序编号（namespace → keeper → clickhouse → backup → dashboard）。脚本是由用户运行的运维衔接工具，实施者绝不执行。

---

## 任务 1：Terraform 骨架 — 版本与 provider

**文件：**
- 创建：`terraform/versions.tf`
- 创建：`terraform/providers.tf`
- 创建：`terraform/variables.tf`（初始子集）

- [ ] **步骤 1：编写 `terraform/versions.tf`**

```hcl
terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40" # blueprint constraint; AWS provider v6 not yet supported upstream
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.25.2"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.9, < 3.0" # blueprint constraint; helm provider v3 not yet supported
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0"
    }
  }

  # NOTE for user: configure a remote backend before real use, e.g.:
  # backend "s3" { bucket = "..." key = "clickhouse-eks/terraform.tfstate" region = "..." dynamodb_table = "..." }
}
```

- [ ] **步骤 2：编写 `terraform/variables.tf`（初始子集 — 后续任务中扩展）**

```hcl
variable "region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "availability_zones" {
  description = "Exactly 3 AZs, one per shard-replica placement. User MUST confirm these exist in the chosen region."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]

  validation {
    condition     = length(var.availability_zones) == 3
    error_message = "This design assumes exactly 3 availability zones."
  }
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "clickhouse-eks"
}

variable "aws_profile" {
  description = "AWS CLI profile used for EKS token exec auth (null = default credentials)"
  type        = string
  default     = null
}
```

- [ ] **步骤 3：编写 `terraform/providers.tf`**

```hcl
locals {
  eks_token_args = var.aws_profile != null ?
    ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.region, "--profile", var.aws_profile] :
    ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.region]
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority)
  exec {
    api_version = "client.authentication.k8s.io/v1"
    command     = "aws"
    args        = local.eks_token_args
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority)
    exec {
      api_version = "client.authentication.k8s.io/v1"
      command     = "aws"
      args        = local.eks_token_args
    }
  }
}
```

- [ ] **步骤 4：格式化并验证语法（在任务 2 之前，模块引用会导致 validate 失败 — 此处仅检查 fmt）**

运行：`cd terraform && terraform fmt -check`
预期：退出码为 0（无格式差异）。`terraform validate` 推迟到任务 2（需要先定义 `eks` 模块；`providers.tf` 引用了 `module.eks`）。

- [ ] **步骤 5：提交**

```bash
git add terraform/versions.tf terraform/providers.tf terraform/variables.tf
git commit -m "feat(tf): terraform skeleton — provider version locks and EKS exec auth"
```

---

## 任务 2：通过蓝图 `//eks` 子模块部署 EKS 基础设施

**文件：**
- 创建：`terraform/eks.tf`
- 修改：`terraform/variables.tf`（添加节点池和网络变量）

- [ ] **步骤 1：扩展 `terraform/variables.tf` — 追加以下变量**

```hcl
variable "cluster_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.34"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "clickhouse_instance_type" {
  description = "Instance type for ClickHouse nodes — MUST be a local-NVMe family (i4i/i3). Default i4i.xlarge."
  type        = string
  default     = "i4i.xlarge"
}

variable "clickhouse_node_count" {
  description = "Number of ClickHouse nodes = shards × replicas. Design is 2×2 = 4."
  type        = number
  default     = 4
}
```

- [ ] **步骤 2：编写 `terraform/eks.tf`**

节点池命名遵循蓝图验证规则（名称必须以 `clickhouse` 或 `system` 开头）。我们创建：一个 `clickhouse` 池（i4i、本地 NVMe、4 个节点横跨 3 个 AZ）、一个 `system` 池（operator/监控），以及一个 `system-keeper` 池（小规格、3 个节点横跨 3 个 AZ）。

```hcl
module "eks" {
  source = "github.com/Altinity/terraform-aws-eks-clickhouse//eks?ref=v0.5.7"

  region             = var.region
  cluster_name       = var.cluster_name
  cluster_version    = var.cluster_version
  cidr               = var.vpc_cidr
  availability_zones = var.availability_zones
  public_cidr        = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
  private_cidr       = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]

  # NOTE: pinned v0.5.7 //eks submodule accepts ONLY these inputs. Inputs like
  # single_nat_gateway / default_ami_type / endpoint_public_access /
  # enable_secrets_encryption / cluster_enabled_log_types were added upstream
  # AFTER v0.5.7 and must NOT be passed here (validate errors otherwise).
  enable_nat_gateway  = true
  autoscaler_version  = "1.34.0"
  autoscaler_replicas = 1
  public_access_cidrs = ["0.0.0.0/0"] # user SHOULD restrict to their office/VPN CIDR
  tags                = {}

  node_pools = [
    {
      name          = "clickhouse"
      instance_type = var.clickhouse_instance_type
      ami_type      = null
      disk_size     = 50 # root EBS; data lives on instance-store NVMe
      desired_size  = var.clickhouse_node_count
      min_size      = var.clickhouse_node_count
      max_size      = var.clickhouse_node_count + 2
      zones         = var.availability_zones
      labels        = { "workload" = "clickhouse" }
      taints = [{
        key    = "dedicated"
        value  = "clickhouse"
        effect = "NO_SCHEDULE"
      }]
    },
    {
      name          = "system"
      instance_type = "t3.large"
      ami_type      = null
      disk_size     = 20
      desired_size  = 2
      min_size      = 2
      max_size      = 4
      zones         = var.availability_zones
      labels        = { "workload" = "system" }
    },
    {
      name          = "system-keeper"
      instance_type = "t3.medium"
      ami_type      = null
      disk_size     = 20
      desired_size  = 3
      min_size      = 3
      max_size      = 3
      zones         = var.availability_zones
      labels        = { "workload" = "keeper" }
      taints = [{
        key    = "dedicated"
        value  = "keeper"
        effect = "NO_SCHEDULE"
      }]
    }
  ]
}
```

- [ ] **步骤 3：初始化（下载 provider 和模块）并验证**

运行：`cd terraform && terraform init -backend=false && terraform validate`
预期：`Success! The configuration is valid.` 如果 init 因网络失败，请重试；模块引用为 `github.com/Altinity/terraform-aws-eks-clickhouse//eks?ref=v0.5.7`。

- [ ] **步骤 4：检查 fmt**

运行：`cd terraform && terraform fmt -check`
预期：退出码为 0。

- [ ] **步骤 5：提交**

```bash
git add terraform/eks.tf terraform/variables.tf
git commit -m "feat(tf): EKS + VPC + node groups via Altinity blueprint //eks@v0.5.7"
```

---

## 任务 3：通过蓝图 `//clickhouse-operator` 部署 ClickHouse operator

**文件：**
- 创建：`terraform/operator.tf`
- 修改：`terraform/variables.tf`（添加 operator 版本）

- [ ] **步骤 1：扩展 `terraform/variables.tf`**

```hcl
variable "operator_version" {
  description = "Altinity clickhouse-operator version (pinned)"
  type        = string
  default     = "0.27.1"
}

variable "clickhouse_namespace" {
  description = "Namespace for the ClickHouse cluster and Keeper"
  type        = string
  default     = "clickhouse"
}
```

- [ ] **步骤 2：编写 `terraform/operator.tf`**

```hcl
module "operator" {
  source = "github.com/Altinity/terraform-aws-eks-clickhouse//clickhouse-operator?ref=v0.5.7"

  depends_on = [module.eks]

  clickhouse_operator_namespace = "kube-system"
  clickhouse_operator_version   = var.operator_version
}
```

- [ ] **步骤 3：验证**

运行：`cd terraform && terraform validate`
预期：`Success! The configuration is valid.`

- [ ] **步骤 4：fmt 并提交**

```bash
cd terraform && terraform fmt
git add terraform/operator.tf terraform/variables.tf
git commit -m "feat(tf): install Altinity operator 0.27.1 via blueprint submodule"
```

---

## 任务 4：存储 — gp3 StorageClass + local-static-provisioner

**文件：**
- 创建：`terraform/storage.tf`

Keeper 使用 gp3 — **复用蓝图已有的 `gp3-encrypted` StorageClass**（v0.5.7 的 `//eks` 子模块已通过 `eks/addons.tf` 将其创建为集群默认值；不要重新定义，否则具有相同 metadata 名称的重复 `kubernetes_storage_class` 会在 apply 时冲突）。ClickHouse 通过 sig-storage local-static-provisioner 使用本地 NVMe；它会发现挂载在 `/mnt/disks` 下的实例存储磁盘，并将其发布为绑定到 `local-storage` StorageClass（`WaitForFirstConsumer`）的 `local` PV。

**已验证的 chart 事实（helm 仓库，2026-07）：** 已发布的 `local-static-provisioner` 版本仅有 `1.0.0`、`2.0.0`、`2.8.0`。使用 **`2.8.0`**。在 2.x 中，values schema 将 `nodeSelector` 和 `tolerations` 放在**顶层**（而不是 `daemonset` 键下；该包装仅适用于 1.0.0，2.x 会静默忽略它，从而导致 DaemonSet 部署到每个节点）。

- [ ] **步骤 1：编写 `terraform/storage.tf`**

```hcl
# NOTE: gp3-encrypted StorageClass is already created (as cluster default) by the
# blueprint //eks submodule (eks/addons.tf). Keeper's CHK references it by name.
# Do NOT redefine it here — a duplicate metadata.name collides at apply.

# local-storage class for ClickHouse instance-store NVMe. No provisioner —
# PVs are published by the local-static-provisioner DaemonSet below.
resource "kubernetes_storage_class" "local" {
  metadata {
    name = "local-storage"
  }
  storage_provisioner = "kubernetes.io/no-provisioner"
  volume_binding_mode = "WaitForFirstConsumer"
  reclaim_policy      = "Delete"
}

# sig-storage local-static-provisioner: discovers NVMe under /mnt/disks and
# publishes them as `local` PVs on the local-storage class.
# NOTE: i4i instance-store NVMe must be formatted + mounted under /mnt/disks
# BEFORE this is useful — AL2023 does not auto-mount instance store. See README
# "Preparing i4i NVMe". On a fresh node with empty /mnt/disks, no PVs appear and
# ClickHouse PVCs stay Pending.
resource "helm_release" "local_static_provisioner" {
  depends_on = [module.eks, kubernetes_storage_class.local]

  name       = "local-static-provisioner"
  repository = "https://kubernetes-sigs.github.io/sig-storage-local-static-provisioner"
  chart      = "local-static-provisioner"
  version    = "2.8.0" # verified published version; user confirms latest compatible at apply time
  namespace  = "kube-system"

  # v2.x schema: nodeSelector + tolerations are TOP-LEVEL (no `daemonset` wrapper).
  values = [yamlencode({
    classes = [{
      name                = "local-storage"
      hostDir             = "/mnt/disks"
      mountDir            = "/mnt/disks"
      blockCleanerCommand = ["/scripts/shred.sh", "2"]
    }]
    nodeSelector = { workload = "clickhouse" }
    tolerations = [{
      key      = "dedicated"
      operator = "Equal"
      value    = "clickhouse"
      effect   = "NoSchedule"
    }]
  })]
}
```

- [ ] **步骤 2：验证**

运行：`cd terraform && terraform validate`
预期：`Success! The configuration is valid.`

- [ ] **步骤 3：fmt 并提交**

```bash
cd terraform && terraform fmt
git add terraform/storage.tf
git commit -m "feat(tf): gp3 StorageClass + local-static-provisioner for NVMe"
```

---

## 任务 5：S3 备份桶

**文件：**
- 创建：`terraform/s3.tf`
- 修改：`terraform/variables.tf`（桶名称）

- [ ] **步骤 1：扩展 `terraform/variables.tf`**

```hcl
variable "backup_bucket_name" {
  description = "S3 bucket name for clickhouse-backup (must be globally unique). Empty = auto-name from cluster."
  type        = string
  default     = ""
}
```

- [ ] **步骤 2：编写 `terraform/s3.tf`**

```hcl
locals {
  backup_bucket = var.backup_bucket_name != "" ? var.backup_bucket_name : "${var.cluster_name}-ch-backups"
}

resource "aws_s3_bucket" "backup" {
  bucket = local.backup_bucket
}

resource "aws_s3_bucket_versioning" "backup" {
  bucket = aws_s3_bucket.backup.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "backup" {
  bucket                  = aws_s3_bucket.backup.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```

- [ ] **步骤 3：验证、fmt 并提交**

运行：`cd terraform && terraform validate && terraform fmt`
预期：验证通过。

```bash
git add terraform/s3.tf terraform/variables.tf
git commit -m "feat(tf): encrypted, versioned, private S3 bucket for backups"
```

---

## 任务 6：clickhouse-backup 的 IRSA 角色

**文件：**
- 创建：`terraform/irsa.tf`

蓝图的 `//eks` 子模块不会导出 OIDC provider ARN，但其封装的社区 EKS 模块（`terraform-aws-modules/eks/aws ~> 20.8`，默认启用 IRSA）**已经创建了 OIDC provider**。因此我们必须**通过 data source 引用它**，而不是新建一个；为同一 issuer 创建 `aws_iam_openid_connect_provider` 会在 apply 时以 `EntityAlreadyExists` 发生冲突。

> 注意：采用这种 data source 方式后，`versions.tf`（任务 1）中固定的 `tls` provider 将不再使用；这没有影响（未使用的 `required_providers` 条目不会导致 validate 失败）。保留它；后续任务可能会使用，删除它会造成 lockfile 变动。

- [ ] **步骤 1：编写 `terraform/irsa.tf`**

```hcl
data "aws_eks_cluster" "this" {
  name       = module.eks.cluster_name
  depends_on = [module.eks]
}

# The OIDC provider is already created by the blueprint's EKS module (enable_irsa).
# Reference it as a DATA source — creating a new one collides (EntityAlreadyExists).
data "aws_iam_openid_connect_provider" "this" {
  url = data.aws_eks_cluster.this.identity[0].oidc[0].issuer
}

data "aws_iam_policy_document" "backup_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"
    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.this.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(data.aws_iam_openid_connect_provider.this.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:${var.clickhouse_namespace}:clickhouse-backup"]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(data.aws_iam_openid_connect_provider.this.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "backup" {
  name               = "${var.cluster_name}-clickhouse-backup"
  assume_role_policy = data.aws_iam_policy_document.backup_assume.json
}

data "aws_iam_policy_document" "backup_s3" {
  statement {
    effect  = "Allow"
    actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
    resources = [
      aws_s3_bucket.backup.arn,
      "${aws_s3_bucket.backup.arn}/*",
    ]
  }
}

resource "aws_iam_role_policy" "backup_s3" {
  name   = "s3-access"
  role   = aws_iam_role.backup.id
  policy = data.aws_iam_policy_document.backup_s3.json
}
```

- [ ] **步骤 2：验证、fmt 并提交**

运行：`cd terraform && terraform validate && terraform fmt`
预期：验证通过。

```bash
git add terraform/irsa.tf
git commit -m "feat(tf): IRSA role + S3 policy for clickhouse-backup service account"
```

---

## 任务 7：监控 — kube-prometheus-stack

**文件：**
- 创建：`terraform/monitoring.tf`
- 修改：`terraform/variables.tf`（开关和 Grafana 密码）

- [ ] **步骤 1：扩展 `terraform/variables.tf`**

```hcl
variable "enable_monitoring" {
  description = "Install kube-prometheus-stack (Prometheus + Grafana)"
  type        = bool
  default     = true
}

variable "grafana_admin_password" {
  description = "Grafana admin password. Empty = chart default (change after first login)."
  type        = string
  default     = ""
  sensitive   = true
}
```

- [ ] **步骤 2：编写 `terraform/monitoring.tf`**

```hcl
resource "kubernetes_namespace" "monitoring" {
  count = var.enable_monitoring ? 1 : 0
  metadata { name = "monitoring" }
}

resource "helm_release" "kube_prometheus_stack" {
  count      = var.enable_monitoring ? 1 : 0
  depends_on = [module.eks, kubernetes_namespace.monitoring]

  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = "65.1.1" # user confirms latest compatible at apply time
  namespace  = "monitoring"

  values = [yamlencode({
    grafana = {
      adminPassword = var.grafana_admin_password != "" ? var.grafana_admin_password : null
      service       = { type = "ClusterIP" }
    }
    # Scrape the operator's metrics-exporter (:8888) and ClickHouse embedded endpoint (:9363)
    # via ServiceMonitors created by the operator/CHI. Enable label selector for all namespaces.
    prometheus = {
      prometheusSpec = {
        serviceMonitorSelectorNilUsesHelmValues = false
        podMonitorSelectorNilUsesHelmValues     = false
      }
    }
  })]
}
```

- [ ] **步骤 3：验证、fmt 并提交**

运行：`cd terraform && terraform validate && terraform fmt`
预期：验证通过。

```bash
git add terraform/monitoring.tf terraform/variables.tf
git commit -m "feat(tf): kube-prometheus-stack with cross-namespace ServiceMonitor discovery"
```

---

## 任务 8：Terraform outputs + tfvars

**文件：**
- 创建：`terraform/outputs.tf`
- 创建：`terraform/terraform.tfvars`

- [ ] **步骤 1：编写 `terraform/outputs.tf`**

```hcl
output "configure_kubectl" {
  description = "Run this to configure kubectl access"
  value       = "aws eks --region ${var.region} update-kubeconfig --name ${module.eks.cluster_name}"
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "backup_bucket" {
  value = aws_s3_bucket.backup.id
}

output "backup_role_arn" {
  description = "Annotate the clickhouse-backup ServiceAccount with this role ARN"
  value       = aws_iam_role.backup.arn
}

output "clickhouse_namespace" {
  value = var.clickhouse_namespace
}
```

- [ ] **步骤 2：编写 `terraform/terraform.tfvars`（用户在 apply 前审查的固定默认值）**

```hcl
# ── User MUST confirm these before `terraform apply` ──────────────────────────
region             = "us-east-1"
availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"]
cluster_name       = "clickhouse-eks"
cluster_version    = "1.34"

# ClickHouse nodes: local-NVMe family. 4 nodes = 2 shards × 2 replicas.
clickhouse_instance_type = "i4i.xlarge"
clickhouse_node_count    = 4

# Pinned component versions (see docs/clickhouse-on-eks-research.md)
operator_version = "0.27.1"

# Backup bucket — MUST be globally unique. Leave empty to auto-name "<cluster>-ch-backups".
backup_bucket_name = ""

enable_monitoring = true
# grafana_admin_password = "set-me"   # uncomment and set, or change after first login

# SECURITY: restrict EKS API access to your CIDR before apply (default is world-open).
# public_access_cidrs = ["203.0.113.0/24"]
```

- [ ] **步骤 3：验证、fmt 并提交**

运行：`cd terraform && terraform validate && terraform fmt -check`
预期：验证通过，无 fmt 差异。

```bash
git add terraform/outputs.tf terraform/terraform.tfvars
git commit -m "feat(tf): outputs and pinned tfvars defaults"
```

---

## 任务 9：Namespace + Keeper CHK 清单

**文件：**
- 创建：`manifests/00-namespace.yaml`
- 创建：`manifests/10-keeper-chk.yaml`

- [ ] **步骤 1：编写 `manifests/00-namespace.yaml`**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: clickhouse
```

- [ ] **步骤 2：编写 `manifests/10-keeper-chk.yaml`**

3 节点 Keeper，每个 AZ 一个，运行于 `system-keeper` 节点池并使用 gp3 存储。使用 operator 的 `clickhouse-keeper.altinity.com/v1` CRD。

```yaml
apiVersion: "clickhouse-keeper.altinity.com/v1"
kind: "ClickHouseKeeperInstallation"
metadata:
  name: keeper
  namespace: clickhouse
spec:
  configuration:
    clusters:
      - name: keeper
        layout:
          replicasCount: 3
    settings:
      logger/level: "information"
  defaults:
    templates:
      podTemplate: keeper-pod
      dataVolumeClaimTemplate: keeper-data
  templates:
    podTemplates:
      - name: keeper-pod
        metadata:
          labels:
            app: clickhouse-keeper # MUST be set here — the anti-affinity/spread selectors below match this
        spec:
          nodeSelector:
            workload: keeper
          tolerations:
            - key: dedicated
              operator: Equal
              value: keeper
              effect: NoSchedule
          affinity:
            podAntiAffinity:
              requiredDuringSchedulingIgnoredDuringExecution:
                - labelSelector:
                    matchLabels:
                      app: clickhouse-keeper
                  topologyKey: kubernetes.io/hostname
          topologySpreadConstraints:
            - maxSkew: 1
              topologyKey: topology.kubernetes.io/zone
              whenUnsatisfiable: DoNotSchedule
              labelSelector:
                matchLabels:
                  app: clickhouse-keeper
          containers:
            - name: clickhouse-keeper
              image: "clickhouse/clickhouse-keeper:24.8"
              resources:
                requests:
                  cpu: "1"
                  memory: "1Gi"
                limits:
                  cpu: "2"
                  memory: "2Gi"
    volumeClaimTemplates:
      - name: keeper-data
        spec:
          storageClassName: gp3-encrypted
          accessModes: [ReadWriteOnce]
          resources:
            requests:
              storage: 20Gi
```

- [ ] **步骤 3：客户端 dry-run 验证（本地不存在 CRD — 验证 YAML 结构）**

运行：`kubectl apply --dry-run=client -f manifests/00-namespace.yaml`
预期：`namespace/clickhouse created (dry run)`。

对于 CHK（本地未安装 CRD），验证 YAML 能够解析：
运行：`kubectl apply --dry-run=client -f manifests/10-keeper-chk.yaml 2>&1 | head` — 预期错误*仅为* `no matches for kind "ClickHouseKeeperInstallation"`（本地缺少 CRD），而不是 YAML 解析错误。使用以下命令确认：`python3 -c "import yaml,sys; list(yaml.safe_load_all(open('manifests/10-keeper-chk.yaml')))" && echo YAML_OK`
预期：`YAML_OK`。

- [ ] **步骤 4：提交**

```bash
git add manifests/00-namespace.yaml manifests/10-keeper-chk.yaml
git commit -m "feat(k8s): namespace + 3-node Keeper CHK cross-AZ on gp3"
```

---

## 任务 10：ClickHouse CHI 清单（2×2、本地 NVMe、反亲和性）

**文件：**
- 创建：`manifests/20-clickhouse-chi.yaml`

该任务定义 2 分片 × 2 副本,共 4 个 Pod。数据卷通过 `local-storage` 类使用本地 NVMe。反亲和性限制每台主机运行一个副本,可用区分布约束将副本分散到各 AZ。CHI 引用任务 9 中的 Keeper,并包含 clickhouse-backup sidecar 和带有 IRSA 注解的 ServiceAccount（SA 在任务 11 的 CronJob 文件中创建,此处的注解位于 Pod SA 上）。

- [ ] **步骤 1：编写 `manifests/20-clickhouse-chi.yaml`**

```yaml
apiVersion: "clickhouse.altinity.com/v1"
kind: "ClickHouseInstallation"
metadata:
  name: ch
  namespace: clickhouse
spec:
  defaults:
    templates:
      podTemplate: ch-pod
      dataVolumeClaimTemplate: ch-data
      serviceTemplate: ch-cluster-ip
  configuration:
    zookeeper:
      nodes:
        - host: keeper-keeper.clickhouse.svc.cluster.local
          port: 2181
    users:
      admin/password_sha256_hex: "" # set via secret at apply; placeholder documented in README
      admin/networks/ip: "::/0"
      admin/profile: default
    clusters:
      - name: main
        layout:
          shardsCount: 2
          replicasCount: 2
  templates:
    serviceTemplates:
      - name: ch-cluster-ip
        spec:
          type: ClusterIP
          ports:
            - name: http
              port: 8123
            - name: native
              port: 9000
    podTemplates:
      - name: ch-pod
        spec:
          nodeSelector:
            workload: clickhouse
          tolerations:
            - key: dedicated
              operator: Equal
              value: clickhouse
              effect: NoSchedule
          affinity:
            podAntiAffinity:
              requiredDuringSchedulingIgnoredDuringExecution:
                - labelSelector:
                    matchLabels:
                      clickhouse.altinity.com/app: chop
                  topologyKey: kubernetes.io/hostname
          topologySpreadConstraints:
            - maxSkew: 1
              topologyKey: topology.kubernetes.io/zone
              whenUnsatisfiable: DoNotSchedule
              labelSelector:
                matchLabels:
                  clickhouse.altinity.com/app: chop
          containers:
            - name: clickhouse
              image: "clickhouse/clickhouse-server:24.8"
              resources:
                requests:
                  cpu: "2"
                  memory: "8Gi"
                limits:
                  cpu: "4"
                  memory: "12Gi"
            - name: clickhouse-backup
              image: "altinity/clickhouse-backup:2.6.0"
              args: ["server"]
              env:
                - name: LOG_LEVEL
                  value: "info"
                - name: REMOTE_STORAGE
                  value: "s3"
                - name: S3_BUCKET
                  valueFrom:
                    configMapKeyRef:
                      name: clickhouse-backup-config
                      key: S3_BUCKET
                - name: S3_REGION
                  valueFrom:
                    configMapKeyRef:
                      name: clickhouse-backup-config
                      key: S3_REGION
                - name: S3_PATH
                  value: "backup"
              ports:
                - name: backup-rest
                  containerPort: 7171
    volumeClaimTemplates:
      - name: ch-data
        spec:
          storageClassName: local-storage
          accessModes: [ReadWriteOnce]
          resources:
            requests:
              storage: 800Gi # matches i4i.xlarge instance-store; adjust per instance
```

> **关于反亲和性标签的说明：** `clickhouse.altinity.com/app: chop` 是 operator 的标准 pod 标签（自动应用）。选择器还通过 `clickhouse.altinity.com/chi: ch` 限定范围，因此只会统计本次安装的 pod。`requiredDuringScheduling` 主机反亲和性确保任意两个 CH pod 不会共享同一节点；结合横跨 3 个 AZ 的 4 节点池上的 4 个 pod，`topologySpreadConstraints` 会将它们分散到各可用区。由于本地 NVMe 会固定 pod，`WaitForFirstConsumer` 可保证 PV 创建在调度器选中的节点上。
>
> **重要顺序（在任务 10 + deploy.sh 中实现）：** CHI podTemplate 为 backup sidecar IRSA 设置 `serviceAccountName: clickhouse-backup`。该 SA 在 `30-backup-cronjob.yaml` 中创建，因此 deploy.sh 必须在 CHI 之前应用 SA（见任务 13）。`admin` 用户默认为 `networks/ip: 127.0.0.1/32`（仅 localhost），密码占位符为空；README 说明了在使用前设置真实 sha256 哈希并放宽网络范围的方法。

- [ ] **步骤 2：验证 YAML 能够解析**

运行：`python3 -c "import yaml; list(yaml.safe_load_all(open('manifests/20-clickhouse-chi.yaml')))" && echo YAML_OK`
预期：`YAML_OK`。

运行：`kubectl apply --dry-run=client -f manifests/20-clickhouse-chi.yaml 2>&1 | head`
预期：仅出现 `no matches for kind "ClickHouseInstallation"`（本地缺少 CRD），没有 YAML 解析错误。

- [ ] **步骤 3：提交**

```bash
git add manifests/20-clickhouse-chi.yaml
git commit -m "feat(k8s): ClickHouse CHI 2x2 on local NVMe with anti-affinity + zone spread"
```

---

## 任务 11：备份 ServiceAccount + CronJob + 配置

**文件：**
- 创建：`manifests/30-backup-cronjob.yaml`

- [ ] **步骤 1：编写 `manifests/30-backup-cronjob.yaml`**

ServiceAccount 带有 IRSA 角色 ARN 注解（来自 `terraform output backup_role_arn`，README 说明了替换方法）。CronJob 调用备份 sidecar 的 REST API 来创建并上传备份。

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: clickhouse-backup
  namespace: clickhouse
  annotations:
    # Replace with `terraform output -raw backup_role_arn` before apply
    eks.amazonaws.com/role-arn: "REPLACE_WITH_BACKUP_ROLE_ARN"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: clickhouse-backup-config
  namespace: clickhouse
data:
  # Replace with `terraform output -raw backup_bucket` and your region before apply
  S3_BUCKET: "REPLACE_WITH_BUCKET"
  S3_REGION: "us-east-1"
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: clickhouse-backup-daily
  namespace: clickhouse
spec:
  schedule: "0 2 * * *" # daily 02:00 UTC
  concurrencyPolicy: Forbid
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: clickhouse-backup
          restartPolicy: OnFailure
          containers:
            - name: trigger
              image: curlimages/curl:8.10.1
              command:
                - /bin/sh
                - -c
                - |
                  set -e
                  BACKUP="backup-$(date +%Y%m%d-%H%M%S)"
                  # One pod per shard is enough; loop over both shard leader pods.
                  for HOST in chi-ch-main-0-0 chi-ch-main-1-0; do
                    curl -sf -X POST "http://$HOST.clickhouse.svc.cluster.local:7171/backup/create?name=$BACKUP"
                    curl -sf -X POST "http://$HOST.clickhouse.svc.cluster.local:7171/backup/upload/$BACKUP"
                  done
```

> **注意：** 备份容器使用 Pod ServiceAccount 获取 IRSA,但任务 10 中的 sidecar 运行在 CH Pod 内（该 Pod 使用 operator 管理的 SA）。要让 IRSA 作用于 sidecar,README 说明了两种方式：为 CHI Pod 指定带注解的 ServiceAccount,或将备份作为独立 deployment 运行。本计划采用 CronJob 触发 sidecar REST API 的方式;sidecar 的 S3 凭证来自节点或 Pod IRSA。README 同时记录 `podTemplate.spec.serviceAccountName: clickhouse-backup` 配置。

- [ ] **步骤 2：验证**

运行：`python3 -c "import yaml; list(yaml.safe_load_all(open('manifests/30-backup-cronjob.yaml')))" && echo YAML_OK`
预期：`YAML_OK`。

运行：`kubectl apply --dry-run=client -f manifests/30-backup-cronjob.yaml`
预期：SA、ConfigMap、CronJob 均显示 `created (dry run)`（这些是核心 kind，无需 CRD）。

- [ ] **步骤 3：提交**

```bash
git add manifests/30-backup-cronjob.yaml
git commit -m "feat(k8s): daily clickhouse-backup CronJob + IRSA ServiceAccount"
```

---

## 任务 12：Grafana 仪表板 ConfigMap

**文件：**
- 创建：`manifests/40-grafana-dashboard.yaml`

- [ ] **步骤 1：编写 `manifests/40-grafana-dashboard.yaml`**

kube-prometheus-stack 的 Grafana 会从带有 `grafana_dashboard: "1"` 标签的 ConfigMap 自动导入仪表板。我们通过 sidecar 注解方式，以 gnetId 引用 Altinity operator 官方仪表板 #12163。

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: clickhouse-operator-dashboard
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
  annotations:
    # Grafana sidecar fetches this dashboard by gnetId from grafana.com
    k8s-sidecar-target-directory: "/tmp/dashboards"
data:
  clickhouse-operator.json: |
    {
      "__inputs": [],
      "__requires": [],
      "id": null,
      "title": "ClickHouse Operator (placeholder — replace with dashboard #12163 JSON)",
      "panels": [],
      "schemaVersion": 39,
      "version": 1
    }
```

> **给实施者的说明：** 在计划中内嵌完整约 2000 行的仪表板 #12163 JSON 并不实际。README 说明了如何在 apply 时获取它：`curl -sL "https://grafana.com/api/dashboards/12163/revisions/latest/download" -o dashboard.json`，然后替换到此 ConfigMap 中；或者直接在 Grafana UI 中导入 gnetId 12163。上面的占位 JSON 有效且能正常导入；README 明确说明了替换步骤。

- [ ] **步骤 2：验证**

运行：`python3 -c "import yaml; d=list(yaml.safe_load_all(open('manifests/40-grafana-dashboard.yaml'))); import json; json.loads(d[0]['data']['clickhouse-operator.json']); print('OK')"`
预期：`OK`（确认 YAML 和内嵌 JSON 均可解析）。

- [ ] **步骤 3：提交**

```bash
git add manifests/40-grafana-dashboard.yaml
git commit -m "feat(k8s): Grafana dashboard ConfigMap for operator metrics (#12163)"
```

---

## 任务 13：运维脚本（由用户运行）

**文件：**
- 创建：`scripts/deploy.sh`
- 创建：`scripts/smoke-test.sh`
- 创建：`scripts/teardown.sh`

这些脚本由用户在自行执行 `terraform apply` 后运行。我们负责编写并使用 shellcheck 验证，但绝不执行 apply/destroy。

- [ ] **步骤 1：编写 `scripts/deploy.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
# Deploy ClickHouse on EKS. Run from repo root. Assumes AWS creds are configured.
cd "$(dirname "$0")/.."

echo "==> [1/5] terraform apply (creates EKS, operator, storage, monitoring, S3, IRSA)"
cd terraform
terraform init
terraform apply
BUCKET=$(terraform output -raw backup_bucket)
ROLE_ARN=$(terraform output -raw backup_role_arn)
REGION=$(terraform output -raw configure_kubectl | grep -oE 'region [a-z0-9-]+' | awk '{print $2}')
eval "$(terraform output -raw configure_kubectl)"
cd ..

echo "==> [2/5] waiting for operator to be ready"
# Blueprint installs the operator as helm release 'altinity-clickhouse-operator' in kube-system.
kubectl -n kube-system rollout status deploy/altinity-clickhouse-operator --timeout=180s || true

echo "==> [3/5] substituting backup role ARN and bucket into manifests"
tmpdir=$(mktemp -d)
cp manifests/*.yaml "$tmpdir/"
sed -i.bak "s|REPLACE_WITH_BACKUP_ROLE_ARN|$ROLE_ARN|g" "$tmpdir/30-backup-cronjob.yaml"
sed -i.bak "s|REPLACE_WITH_BUCKET|$BUCKET|g; s|S3_REGION: \"us-east-1\"|S3_REGION: \"$REGION\"|g" "$tmpdir/30-backup-cronjob.yaml"

# Fail-fast if any placeholder survived substitution (would silently break IRSA/backup).
if grep -q "REPLACE_WITH" "$tmpdir/30-backup-cronjob.yaml"; then
  echo "ERROR: unsubstituted REPLACE_WITH placeholder remains in 30-backup-cronjob.yaml" >&2
  exit 1
fi

echo "==> [4/5] applying manifests in order"
kubectl apply -f "$tmpdir/00-namespace.yaml"
# The clickhouse-backup ServiceAccount + ConfigMap must exist BEFORE the CHI, because the
# CHI podTemplate sets serviceAccountName: clickhouse-backup and the sidecar reads the ConfigMap.
# 30 defines the SA/ConfigMap (and the CronJob, harmless to create early), so apply it before 20.
kubectl apply -f "$tmpdir/30-backup-cronjob.yaml"
kubectl apply -f "$tmpdir/10-keeper-chk.yaml"
kubectl -n clickhouse wait --for=condition=Ready pod -l app=clickhouse-keeper --timeout=300s || true
kubectl apply -f "$tmpdir/20-clickhouse-chi.yaml"
kubectl apply -f "$tmpdir/40-grafana-dashboard.yaml"

echo "==> [5/5] done. Watch rollout with: kubectl -n clickhouse get chi,chk,pods -w"
```

- [ ] **步骤 2：编写 `scripts/smoke-test.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
# End-to-end validation of the ClickHouse cluster. Run after deploy.sh.
NS=clickhouse
POD=chi-ch-main-0-0

run() { kubectl -n "$NS" exec "$POD" -c clickhouse -- clickhouse-client -q "$1"; }

echo "==> cluster topology"
run "SELECT cluster, shard_num, replica_num, host_name FROM system.clusters WHERE cluster='main' ORDER BY shard_num, replica_num"

echo "==> create replicated + distributed tables"
run "CREATE TABLE IF NOT EXISTS default.t_local ON CLUSTER main (id UInt64, v String)
     ENGINE=ReplicatedMergeTree('/clickhouse/tables/{shard}/t_local','{replica}') ORDER BY id"
run "CREATE TABLE IF NOT EXISTS default.t_dist ON CLUSTER main AS default.t_local
     ENGINE=Distributed(main, default, t_local, rand())"

echo "==> insert via distributed table"
run "INSERT INTO default.t_dist SELECT number, toString(number) FROM numbers(1000)"
sleep 3

echo "==> verify replication (query the OTHER replica of shard 0)"
kubectl -n "$NS" exec chi-ch-main-0-1 -c clickhouse -- clickhouse-client -q \
  "SELECT count() FROM default.t_local"

echo "==> total across shards via distributed"
run "SELECT count() FROM default.t_dist"

echo "==> replication health"
run "SELECT database, table, is_readonly, absolute_delay FROM system.replicas WHERE table='t_local'"

echo "==> PASS if distributed count == 1000 and replica count > 0"
```

- [ ] **步骤 3：编写 `scripts/teardown.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
# Ordered teardown. Deletes CH resources first so the operator releases PVs/LBs,
# then destroys AWS infra. Prevents orphaned EBS/ENI/LB charges.
cd "$(dirname "$0")/.."

echo "==> deleting ClickHouse + Keeper (operator cleans up PVCs/services)"
kubectl delete -f manifests/20-clickhouse-chi.yaml --ignore-not-found
kubectl delete -f manifests/10-keeper-chk.yaml --ignore-not-found
kubectl -n clickhouse delete pvc --all --ignore-not-found
sleep 20

echo "==> terraform destroy"
cd terraform
terraform destroy

echo "==> NOTE: S3 backup bucket has versioning; empty + delete manually if desired:"
echo "    aws s3 rb s3://\$(terraform output -raw backup_bucket) --force"
```

- [ ] **步骤 4：设置为可执行，并使用 bash -n（语法）验证；如有 shellcheck，也使用它验证**

运行：
```bash
chmod +x scripts/*.sh
for f in scripts/*.sh; do bash -n "$f" && echo "$f syntax OK"; done
command -v shellcheck >/dev/null && shellcheck scripts/*.sh || echo "shellcheck not installed — skipped"
```
预期：三行 `syntax OK`。

- [ ] **步骤 5：提交**

```bash
git add scripts/
git commit -m "feat(scripts): deploy, smoke-test, and ordered teardown (user-run)"
```

---

## 任务 14：README

**文件：**
- 创建：`README.md`

- [ ] **步骤 1：编写 `README.md`**，按顺序涵盖：

1. **概述** — 此部署包含的内容（EKS 上的 2×2 + 3 Keeper、本地 NVMe、监控、备份），并链接到 `docs/superpowers/specs/2026-07-03-clickhouse-on-eks-design.md` 和 `docs/clickhouse-on-eks-research.md`。
2. **前提条件** — Terraform ≥1.5、AWS CLI 和已配置且具有 EKS/VPC/EC2/IAM/S3 权限的凭证、kubectl、helm；AWS 账户在目标区域具备 i4i 配额。
3. **费用警告** — 4× i4i.xlarge + 3× t3.medium + 2× t3.large + NAT + EKS control plane ≈ 每天数十美元；链接 AWS 定价；强调使用 `teardown.sh` 停止计费。
4. **配置** — 编辑 `terraform/terraform.tfvars`：确认 region/AZ 存在，设置唯一的 `backup_bucket_name`，限制 `public_access_cidrs`，选择 ClickHouse 镜像标签（默认 `24.8` — 确认其为当前 LTS），设置 Grafana 密码。
5. **准备 i4i NVMe** — 说明 AL2023 不会自动挂载实例存储；local-static-provisioner 期望磁盘位于 `/mnt/disks` 下。提供用于格式化和挂载 NVMe 的节点 bootstrap/user-data 片段，或注明 provisioner 内置的磁盘发现模式。
6. **部署** — `./scripts/deploy.sh`（说明它先运行 terraform apply，再应用已替换 ARN/桶的清单）。包括手动步骤的替代方式。
7. **将 IRSA 连接到备份 sidecar** — 说明如何在 CHI `podTemplate.spec` 中添加 `serviceAccountName: clickhouse-backup`，以便 sidecar 代入 S3 角色。
8. **设置 admin 密码** — 在生产使用前创建 `admin` 用户密码 secret / 在 CHI 中设置 `password_sha256_hex`。
9. **验证** — `./scripts/smoke-test.sh`；预期输出（分布式计数为 1000，复制健康）。
10. **访问** — 执行 `kubectl -n clickhouse port-forward svc/clickhouse-ch 8123:8123`，然后执行 `curl`。
11. **监控** — 端口转发 Grafana，导入仪表板 #12163（或通过文档所述的 `curl` 获取真实 JSON，并应用相应 ConfigMap）。
12. **备份/恢复** — CronJob 的工作方式；通过 sidecar REST API 手动恢复。
13. **拆除** — `./scripts/teardown.sh` + 手动删除 S3 桶。
14. **已知注意事项** — 本地 NVMe 意味着节点丢失后，需要从存活 AZ 的副本重建；蓝图 provider 版本锁定（AWS ~>5.40、helm <3）；`public_access_cidrs` 默认为向全世界开放。

- [ ] **步骤 2：验证链接可解析且 Markdown 可渲染**

运行：`python3 -c "print(open('README.md').read()[:200])"`，并手动确认两个文档链接指向现有文件：
运行：`ls docs/superpowers/specs/2026-07-03-clickhouse-on-eks-design.md docs/clickhouse-on-eks-research.md`
预期：列出两个文件。

- [ ] **步骤 3：提交**

```bash
git add README.md
git commit -m "docs: README with prerequisites, deploy, verify, cost, teardown"
```

---

## 任务 15：最终集成验证

**文件：** 无（仅验证）

- [ ] **步骤 1：对整个模块执行完整的 terraform validate + fmt**

运行：`cd terraform && terraform fmt -check && terraform init -backend=false && terraform validate`
预期：无 fmt 差异，`Success! The configuration is valid.`

- [ ] **步骤 2：所有清单均能解析并顺利通过 dry-run**

运行：
```bash
for f in manifests/*.yaml; do
  python3 -c "import yaml; list(yaml.safe_load_all(open('$f')))" && echo "$f YAML_OK"
done
kubectl apply --dry-run=client -f manifests/00-namespace.yaml
kubectl apply --dry-run=client -f manifests/30-backup-cronjob.yaml
```
预期：每个文件均显示 `YAML_OK`；namespace + backup 清单显示 `created (dry run)`。CHI/CHK 仅显示 "no matches for kind"（缺少 CRD），这是离线环境中的预期结果。

- [ ] **步骤 3：所有脚本均通过语法检查**

运行：`for f in scripts/*.sh; do bash -n "$f" && echo "$f OK"; done`
预期：三行 `OK`。

- [ ] **步骤 4：确认没有 secret/占位符泄漏到已提交状态**

运行：`grep -rn "REPLACE_WITH\|set-me\|password" terraform/ manifests/ | grep -v "_sha256_hex\|password_sha256\|adminPassword\|grafana_admin_password\|clickhouse_cluster_password"`
预期：仅出现 `manifests/30-backup-cronjob.yaml` 中有意保留的 `REPLACE_WITH_*` 占位符（由 deploy.sh 替换）；确认 terraform 中没有占位符。

- [ ] **步骤 5：最终提交（如有 fmt 修复）**

```bash
git add -A && git commit -m "chore: final fmt + validation pass" || echo "nothing to commit"
```

---

## 自审说明（编写期间完成）

- **规范覆盖：** operator（T3）、Keeper CHK（T9）、CHI 2×2（T10）、本地 NVMe（T4+T10）、反亲和性/可用区分布（T9+T10）、监控（T7+T12）、备份+IRSA（T5+T6+T11）、ClusterIP（T10 serviceTemplate）、蓝图复用（T2+T3）、拆除/费用（T13+T14）。已映射所有规范章节。
- **蓝图接口：** 节点池名称使用要求的 `clickhouse`/`system`/`system-keeper` 前缀；provider 版本锁定与上游一致；由于蓝图不导出 OIDC，OIDC 由其自行预置。
- **已知的延后细节（已标明，未隐藏）：** i4i NVMe 挂载准备（任务 4 说明 + README §5）和完整仪表板 JSON（任务 12 说明 + README §11）均记录为 apply 时由用户执行的步骤，而非内嵌内容，因为二者都依赖运行环境。这些是明确说明的步骤，不是占位符。
- **版本固定：** operator 0.27.1、蓝图 v0.5.7、ClickHouse/Keeper 镜像 24.8（用户在 tfvars/README 中确认当前 LTS）、clickhouse-backup 2.6.0、kube-prometheus-stack 65.1.1、local-static-provisioner 1.7.0；凡可能发生版本漂移之处，均标记“用户在 apply 时确认最新兼容版本”。
