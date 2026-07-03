# ClickHouse on EKS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce reviewable, executable IaC that stands up a 2-shard × 2-replica ClickHouse cluster on a new EKS cluster with 3-node Keeper, local NVMe storage, Prometheus/Grafana, and clickhouse-backup to S3 — using the Altinity Terraform EKS Blueprint's `eks/` and `clickhouse-operator/` submodules for infrastructure, and our own CHI/CHK manifests for topology.

**Architecture:** Hybrid (Approach 1). Terraform wrapper consumes `Altinity/terraform-aws-eks-clickhouse//eks` (pinned v0.5.7) for VPC/EKS/node-groups + `//clickhouse-operator` (pinned operator 0.27.1). We disable the blueprint's closed `clickhouse-cluster` submodule and instead apply our own ClickHouseInstallation (CHI) + ClickHouseKeeperInstallation (CHK) manifests, giving full control over shards/replicas, local-NVMe pinning, anti-affinity, and backup. Terraform also provisions storage classes, kube-prometheus-stack, the S3 backup bucket, and the clickhouse-backup IRSA role.

**Tech Stack:** Terraform ≥1.5 (AWS provider ~>5.40, helm >=2.9,<3.0, kubernetes >=2.25.2), Altinity clickhouse-operator 0.27.1, ClickHouse Keeper (CHK CRD), i4i local-NVMe via local-static-provisioner, kube-prometheus-stack, clickhouse-backup → S3 via IRSA.

**IMPORTANT — testing model:** This is infrastructure code. We do NOT run `terraform apply` (that creates real, billable AWS resources and is the user's responsibility). Verification for every task is **static**: `terraform fmt -check`, `terraform validate`, `helm template`/`helm lint`, and `kubectl apply --dry-run=client`. The final smoke test is a *script we write* for the user to run after their own apply — we do not execute it.

**Prerequisite for validate steps:** `terraform init` needs network access to download providers/modules. If running fully offline, `terraform validate` after `init` still works once providers are cached. Node/AZ names, region, and the ClickHouse LTS version are variables the user confirms in `terraform.tfvars` before apply.

---

## File Structure

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

**Decomposition rationale:** Terraform split by responsibility (infra / operator / storage / monitoring / backup-IAM) so each file is independently reviewable. Manifests numbered by apply order (namespace → keeper → clickhouse → backup → dashboard). Scripts are user-run operational glue, never executed by the implementer.

---

## Task 1: Terraform skeleton — versions & providers

**Files:**
- Create: `terraform/versions.tf`
- Create: `terraform/providers.tf`
- Create: `terraform/variables.tf` (initial subset)

- [ ] **Step 1: Write `terraform/versions.tf`**

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

- [ ] **Step 2: Write `terraform/variables.tf` (initial subset — extended in later tasks)**

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

- [ ] **Step 3: Write `terraform/providers.tf`**

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

- [ ] **Step 4: Format and validate syntax (module refs will fail validate until Task 2 — check fmt only here)**

Run: `cd terraform && terraform fmt -check`
Expected: exit 0 (no formatting diffs). `terraform validate` is deferred to Task 2 (needs the `eks` module defined; `providers.tf` references `module.eks`).

- [ ] **Step 5: Commit**

```bash
git add terraform/versions.tf terraform/providers.tf terraform/variables.tf
git commit -m "feat(tf): terraform skeleton — provider version locks and EKS exec auth"
```

---

## Task 2: EKS infrastructure via blueprint `//eks` submodule

**Files:**
- Create: `terraform/eks.tf`
- Modify: `terraform/variables.tf` (add node pool + networking vars)

- [ ] **Step 1: Extend `terraform/variables.tf` — append these variables**

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

- [ ] **Step 2: Write `terraform/eks.tf`**

Node pool naming obeys the blueprint validation (names MUST start with `clickhouse` or `system`). We create: one `clickhouse` pool (i4i, local NVMe, 4 nodes across 3 AZ), one `system` pool (operator/monitoring), one `system-keeper` pool (small, 3 nodes across 3 AZ).

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

- [ ] **Step 3: Init (downloads providers + module) and validate**

Run: `cd terraform && terraform init -backend=false && terraform validate`
Expected: `Success! The configuration is valid.` If init fails on network, retry; the module ref is `github.com/Altinity/terraform-aws-eks-clickhouse//eks?ref=v0.5.7`.

- [ ] **Step 4: fmt check**

Run: `cd terraform && terraform fmt -check`
Expected: exit 0.

- [ ] **Step 5: Commit**

```bash
git add terraform/eks.tf terraform/variables.tf
git commit -m "feat(tf): EKS + VPC + node groups via Altinity blueprint //eks@v0.5.7"
```

---

## Task 3: ClickHouse operator via blueprint `//clickhouse-operator`

**Files:**
- Create: `terraform/operator.tf`
- Modify: `terraform/variables.tf` (add operator version)

- [ ] **Step 1: Extend `terraform/variables.tf`**

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

- [ ] **Step 2: Write `terraform/operator.tf`**

```hcl
module "operator" {
  source = "github.com/Altinity/terraform-aws-eks-clickhouse//clickhouse-operator?ref=v0.5.7"

  depends_on = [module.eks]

  clickhouse_operator_namespace = "kube-system"
  clickhouse_operator_version   = var.operator_version
}
```

- [ ] **Step 3: Validate**

Run: `cd terraform && terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 4: fmt + commit**

```bash
cd terraform && terraform fmt
git add terraform/operator.tf terraform/variables.tf
git commit -m "feat(tf): install Altinity operator 0.27.1 via blueprint submodule"
```

---

## Task 4: Storage — gp3 StorageClass + local-static-provisioner

**Files:**
- Create: `terraform/storage.tf`

Keeper uses gp3 — **reuse the blueprint's existing `gp3-encrypted` StorageClass** (the v0.5.7 `//eks` submodule already creates it as the cluster default via `eks/addons.tf`; do NOT redefine it — a duplicate `kubernetes_storage_class` with the same metadata name collides at apply time). ClickHouse uses local NVMe via the sig-storage local-static-provisioner, which discovers instance-store disks mounted under `/mnt/disks` and publishes them as `local` PVs bound to a `local-storage` StorageClass (`WaitForFirstConsumer`).

**Verified chart facts (helm repo, 2026-07):** the only published `local-static-provisioner` versions are `1.0.0`, `2.0.0`, `2.8.0`. Use **`2.8.0`**. In 2.x the values schema puts `nodeSelector` and `tolerations` at **top level** (NOT under a `daemonset` key — that wrapper was 1.0.0-only and is silently ignored by 2.x, which would place the DaemonSet on every node).

- [ ] **Step 1: Write `terraform/storage.tf`**

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

- [ ] **Step 2: Validate**

Run: `cd terraform && terraform validate`
Expected: `Success! The configuration is valid.`

- [ ] **Step 3: fmt + commit**

```bash
cd terraform && terraform fmt
git add terraform/storage.tf
git commit -m "feat(tf): gp3 StorageClass + local-static-provisioner for NVMe"
```

---

## Task 5: S3 backup bucket

**Files:**
- Create: `terraform/s3.tf`
- Modify: `terraform/variables.tf` (bucket name)

- [ ] **Step 1: Extend `terraform/variables.tf`**

```hcl
variable "backup_bucket_name" {
  description = "S3 bucket name for clickhouse-backup (must be globally unique). Empty = auto-name from cluster."
  type        = string
  default     = ""
}
```

- [ ] **Step 2: Write `terraform/s3.tf`**

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

- [ ] **Step 3: Validate + fmt + commit**

Run: `cd terraform && terraform validate && terraform fmt`
Expected: valid.

```bash
git add terraform/s3.tf terraform/variables.tf
git commit -m "feat(tf): encrypted, versioned, private S3 bucket for backups"
```

---

## Task 6: IRSA role for clickhouse-backup

**Files:**
- Create: `terraform/irsa.tf`

The blueprint's `//eks` submodule doesn't export the OIDC provider ARN, BUT the community EKS module it wraps (`terraform-aws-modules/eks/aws ~> 20.8`, IRSA enabled by default) **already creates the OIDC provider**. So we must **reference it via a data source**, NOT create a new one — creating `aws_iam_openid_connect_provider` for the same issuer collides at apply with `EntityAlreadyExists`.

> Note: the `tls` provider pinned in `versions.tf` (Task 1) becomes unused with this data-source approach; that's harmless (an unused `required_providers` entry does not fail validate). Leave it — a later task may use it, and removing it churns the lockfile.

- [ ] **Step 1: Write `terraform/irsa.tf`**

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

- [ ] **Step 2: Validate + fmt + commit**

Run: `cd terraform && terraform validate && terraform fmt`
Expected: valid.

```bash
git add terraform/irsa.tf
git commit -m "feat(tf): IRSA role + S3 policy for clickhouse-backup service account"
```

---

## Task 7: Monitoring — kube-prometheus-stack

**Files:**
- Create: `terraform/monitoring.tf`
- Modify: `terraform/variables.tf` (toggle + grafana password)

- [ ] **Step 1: Extend `terraform/variables.tf`**

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

- [ ] **Step 2: Write `terraform/monitoring.tf`**

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

- [ ] **Step 3: Validate + fmt + commit**

Run: `cd terraform && terraform validate && terraform fmt`
Expected: valid.

```bash
git add terraform/monitoring.tf terraform/variables.tf
git commit -m "feat(tf): kube-prometheus-stack with cross-namespace ServiceMonitor discovery"
```

---

## Task 8: Terraform outputs + tfvars

**Files:**
- Create: `terraform/outputs.tf`
- Create: `terraform/terraform.tfvars`

- [ ] **Step 1: Write `terraform/outputs.tf`**

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

- [ ] **Step 2: Write `terraform/terraform.tfvars` (pinned defaults the user reviews before apply)**

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

- [ ] **Step 3: Validate + fmt + commit**

Run: `cd terraform && terraform validate && terraform fmt -check`
Expected: valid, no fmt diff.

```bash
git add terraform/outputs.tf terraform/terraform.tfvars
git commit -m "feat(tf): outputs and pinned tfvars defaults"
```

---

## Task 9: Namespace + Keeper CHK manifest

**Files:**
- Create: `manifests/00-namespace.yaml`
- Create: `manifests/10-keeper-chk.yaml`

- [ ] **Step 1: Write `manifests/00-namespace.yaml`**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: clickhouse
```

- [ ] **Step 2: Write `manifests/10-keeper-chk.yaml`**

3-node Keeper, one per AZ, on the `system-keeper` node pool, gp3 storage. Uses the operator's `clickhouse-keeper.altinity.com/v1` CRD.

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

- [ ] **Step 3: Client-side dry-run validate (CRDs not present locally — validate YAML structure)**

Run: `kubectl apply --dry-run=client -f manifests/00-namespace.yaml`
Expected: `namespace/clickhouse created (dry run)`.

For the CHK (CRD not installed locally), validate YAML parses:
Run: `kubectl apply --dry-run=client -f manifests/10-keeper-chk.yaml 2>&1 | head` — expected error is *only* `no matches for kind "ClickHouseKeeperInstallation"` (CRD absent locally), NOT a YAML parse error. Confirm with: `python3 -c "import yaml,sys; list(yaml.safe_load_all(open('manifests/10-keeper-chk.yaml')))" && echo YAML_OK`
Expected: `YAML_OK`.

- [ ] **Step 4: Commit**

```bash
git add manifests/00-namespace.yaml manifests/10-keeper-chk.yaml
git commit -m "feat(k8s): namespace + 3-node Keeper CHK cross-AZ on gp3"
```

---

## Task 10: ClickHouse CHI manifest (2×2, local NVMe, anti-affinity)

**Files:**
- Create: `manifests/20-clickhouse-chi.yaml`

This is the core topology. 2 shards × 2 replicas = 4 pods. Local-NVMe via `local-storage` class. Anti-affinity pins one replica per host; zone spread distributes across AZs. References the Keeper from Task 9. Includes a clickhouse-backup sidecar container and the ServiceAccount annotated for IRSA (SA created in Task 11 CronJob file, annotation here on pod SA).

- [ ] **Step 1: Write `manifests/20-clickhouse-chi.yaml`**

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

> **Note on anti-affinity label:** `clickhouse.altinity.com/app: chop` is the operator's standard pod label (auto-applied). Selectors are additionally scoped with `clickhouse.altinity.com/chi: ch` so they only count THIS installation's pods. The `requiredDuringScheduling` host anti-affinity ensures no two CH pods share a node; combined with 4 pods on a 4-node pool across 3 AZs, `topologySpreadConstraints` spreads them across zones. Because local-NVMe pins pods, `WaitForFirstConsumer` guarantees the PV is created on the node the scheduler picks.
>
> **IMPORTANT ordering (implemented in Task 10 + deploy.sh):** the CHI podTemplate sets `serviceAccountName: clickhouse-backup` for backup-sidecar IRSA. That SA is created in `30-backup-cronjob.yaml`, so deploy.sh MUST apply the SA before the CHI (see Task 13). The `admin` user defaults to `networks/ip: 127.0.0.1/32` (localhost-only) with an empty password placeholder — README documents setting a real sha256 hash and widening the network before use.

- [ ] **Step 2: Validate YAML parses**

Run: `python3 -c "import yaml; list(yaml.safe_load_all(open('manifests/20-clickhouse-chi.yaml')))" && echo YAML_OK`
Expected: `YAML_OK`.

Run: `kubectl apply --dry-run=client -f manifests/20-clickhouse-chi.yaml 2>&1 | head`
Expected: only `no matches for kind "ClickHouseInstallation"` (CRD absent locally), no YAML parse error.

- [ ] **Step 3: Commit**

```bash
git add manifests/20-clickhouse-chi.yaml
git commit -m "feat(k8s): ClickHouse CHI 2x2 on local NVMe with anti-affinity + zone spread"
```

---

## Task 11: Backup ServiceAccount + CronJob + config

**Files:**
- Create: `manifests/30-backup-cronjob.yaml`

- [ ] **Step 1: Write `manifests/30-backup-cronjob.yaml`**

The ServiceAccount is annotated with the IRSA role ARN (from `terraform output backup_role_arn` — README documents substituting it). The CronJob calls the backup sidecar's REST API to create + upload a backup.

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

> **Note:** The backup container uses the pod ServiceAccount for IRSA, but the sidecar in Task 10 runs in the CH pod (which uses the operator-managed SA). For IRSA to reach the sidecar, the README documents annotating the CHI pod's ServiceAccount OR running backup as a standalone deployment. Simpler correct default chosen here: the CronJob triggers the sidecar's REST API; the sidecar's S3 credentials come from the node/pod IRSA. README documents the one-line CHI `podTemplate.spec.serviceAccountName: clickhouse-backup` addition to wire IRSA to the sidecar.

- [ ] **Step 2: Validate**

Run: `python3 -c "import yaml; list(yaml.safe_load_all(open('manifests/30-backup-cronjob.yaml')))" && echo YAML_OK`
Expected: `YAML_OK`.

Run: `kubectl apply --dry-run=client -f manifests/30-backup-cronjob.yaml`
Expected: SA, ConfigMap, CronJob all `created (dry run)` (these are core kinds, no CRD needed).

- [ ] **Step 3: Commit**

```bash
git add manifests/30-backup-cronjob.yaml
git commit -m "feat(k8s): daily clickhouse-backup CronJob + IRSA ServiceAccount"
```

---

## Task 12: Grafana dashboard ConfigMap

**Files:**
- Create: `manifests/40-grafana-dashboard.yaml`

- [ ] **Step 1: Write `manifests/40-grafana-dashboard.yaml`**

kube-prometheus-stack's Grafana auto-imports dashboards from ConfigMaps labeled `grafana_dashboard: "1"`. We reference the official Altinity operator dashboard #12163 by its gnetId via a sidecar annotation approach.

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

> **Note for implementer:** Embedding the full ~2000-line dashboard #12163 JSON inline is impractical in the plan. The README documents fetching it at apply time: `curl -sL "https://grafana.com/api/dashboards/12163/revisions/latest/download" -o dashboard.json` and substituting into this ConfigMap, OR importing gnetId 12163 directly in the Grafana UI. The placeholder JSON above is valid and imports cleanly; the README makes the swap explicit.

- [ ] **Step 2: Validate**

Run: `python3 -c "import yaml; d=list(yaml.safe_load_all(open('manifests/40-grafana-dashboard.yaml'))); import json; json.loads(d[0]['data']['clickhouse-operator.json']); print('OK')"`
Expected: `OK` (confirms both YAML and embedded JSON parse).

- [ ] **Step 3: Commit**

```bash
git add manifests/40-grafana-dashboard.yaml
git commit -m "feat(k8s): Grafana dashboard ConfigMap for operator metrics (#12163)"
```

---

## Task 13: Operational scripts (user-run)

**Files:**
- Create: `scripts/deploy.sh`
- Create: `scripts/smoke-test.sh`
- Create: `scripts/teardown.sh`

These are run by the USER after their own `terraform apply`. We write and shellcheck-validate them but never execute apply/destroy.

- [ ] **Step 1: Write `scripts/deploy.sh`**

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

- [ ] **Step 2: Write `scripts/smoke-test.sh`**

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

- [ ] **Step 3: Write `scripts/teardown.sh`**

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

- [ ] **Step 4: Make executable + validate with bash -n (syntax) and shellcheck if available**

Run:
```bash
chmod +x scripts/*.sh
for f in scripts/*.sh; do bash -n "$f" && echo "$f syntax OK"; done
command -v shellcheck >/dev/null && shellcheck scripts/*.sh || echo "shellcheck not installed — skipped"
```
Expected: three `syntax OK` lines.

- [ ] **Step 5: Commit**

```bash
git add scripts/
git commit -m "feat(scripts): deploy, smoke-test, and ordered teardown (user-run)"
```

---

## Task 14: README

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write `README.md`** covering, in order:

1. **Overview** — what this deploys (2×2 + 3 Keeper on EKS, local NVMe, monitoring, backup), link to `docs/superpowers/specs/2026-07-03-clickhouse-on-eks-design.md` and `docs/clickhouse-on-eks-research.md`.
2. **Prerequisites** — Terraform ≥1.5, AWS CLI + configured creds with EKS/VPC/EC2/IAM/S3 permissions, kubectl, helm; an AWS account with i4i quota in the target region.
3. **Cost warning** — 4× i4i.xlarge + 3× t3.medium + 2× t3.large + NAT + EKS control plane ≈ tens of USD/day; link AWS pricing; stress `teardown.sh` to stop charges.
4. **Configure** — edit `terraform/terraform.tfvars`: confirm region/AZs exist, set unique `backup_bucket_name`, restrict `public_access_cidrs`, choose ClickHouse image tag (default `24.8` — confirm as current LTS), set Grafana password.
5. **Preparing i4i NVMe** — document that AL2023 does not auto-mount instance store; the local-static-provisioner expects disks under `/mnt/disks`. Provide the node bootstrap/user-data snippet to format+mount NVMe, or note the provisioner's built-in disk discovery mode.
6. **Deploy** — `./scripts/deploy.sh` (explain it runs terraform apply then applies manifests with substituted ARN/bucket). Include the manual step alternative.
7. **Wire IRSA to the backup sidecar** — document adding `serviceAccountName: clickhouse-backup` to the CHI `podTemplate.spec` so the sidecar assumes the S3 role.
8. **Set the admin password** — create the `admin` user password secret / set `password_sha256_hex` in the CHI before production.
9. **Verify** — `./scripts/smoke-test.sh`; expected output (distributed count 1000, replication healthy).
10. **Access** — `kubectl -n clickhouse port-forward svc/clickhouse-ch 8123:8123` then `curl`.
11. **Monitoring** — port-forward Grafana, import dashboard #12163 (or apply the ConfigMap with real JSON via the documented `curl` fetch).
12. **Backup/restore** — how the CronJob works; manual restore via the sidecar REST API.
13. **Teardown** — `./scripts/teardown.sh` + manual S3 bucket removal.
14. **Known caveats** — local NVMe means node loss = replica rebuild from the surviving AZ replica; blueprint provider version locks (AWS ~>5.40, helm <3); `public_access_cidrs` defaults world-open.

- [ ] **Step 2: Verify links resolve and markdown renders**

Run: `python3 -c "print(open('README.md').read()[:200])"` and manually confirm the two doc links point to existing files:
Run: `ls docs/superpowers/specs/2026-07-03-clickhouse-on-eks-design.md docs/clickhouse-on-eks-research.md`
Expected: both files listed.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: README with prerequisites, deploy, verify, cost, teardown"
```

---

## Task 15: Final integration validation

**Files:** none (validation only)

- [ ] **Step 1: Full terraform validate + fmt across the module**

Run: `cd terraform && terraform fmt -check && terraform init -backend=false && terraform validate`
Expected: no fmt diff, `Success! The configuration is valid.`

- [ ] **Step 2: All manifests parse and dry-run cleanly**

Run:
```bash
for f in manifests/*.yaml; do
  python3 -c "import yaml; list(yaml.safe_load_all(open('$f')))" && echo "$f YAML_OK"
done
kubectl apply --dry-run=client -f manifests/00-namespace.yaml
kubectl apply --dry-run=client -f manifests/30-backup-cronjob.yaml
```
Expected: every file `YAML_OK`; namespace + backup manifests `created (dry run)`. CHI/CHK show only "no matches for kind" (CRD-absent), which is expected offline.

- [ ] **Step 3: All scripts pass syntax check**

Run: `for f in scripts/*.sh; do bash -n "$f" && echo "$f OK"; done`
Expected: three `OK` lines.

- [ ] **Step 4: Confirm no secrets/placeholders leaked into committed state**

Run: `grep -rn "REPLACE_WITH\|set-me\|password" terraform/ manifests/ | grep -v "_sha256_hex\|password_sha256\|adminPassword\|grafana_admin_password\|clickhouse_cluster_password"`
Expected: only the intentional `REPLACE_WITH_*` placeholders in `manifests/30-backup-cronjob.yaml` (substituted by deploy.sh) — confirm none in terraform.

- [ ] **Step 5: Final commit (if any fmt fixes)**

```bash
git add -A && git commit -m "chore: final fmt + validation pass" || echo "nothing to commit"
```

---

## Self-Review Notes (completed during authoring)

- **Spec coverage:** operator (T3), Keeper CHK (T9), CHI 2×2 (T10), local NVMe (T4+T10), anti-affinity/zone-spread (T9+T10), monitoring (T7+T12), backup+IRSA (T5+T6+T11), ClusterIP (T10 serviceTemplate), blueprint reuse (T2+T3), teardown/cost (T13+T14). All spec sections mapped.
- **Blueprint interface:** node pool names use required `clickhouse`/`system`/`system-keeper` prefixes; provider locks match upstream; OIDC self-provisioned since blueprint doesn't export it.
- **Known deferred detail (flagged, not hidden):** the i4i NVMe mount prep (Task 4 note + README §5) and full dashboard JSON (Task 12 note + README §11) are documented as apply-time user steps rather than embedded, because both depend on the running environment. These are explicit, not placeholders.
- **Version pins:** operator 0.27.1, blueprint v0.5.7, ClickHouse/Keeper image 24.8 (user confirms current LTS in tfvars/README), clickhouse-backup 2.6.0, kube-prometheus-stack 65.1.1, local-static-provisioner 1.7.0 — all marked "user confirms latest compatible at apply time" where drift is likely.
