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

  validation {
    condition     = can(regex("^[a-z0-9-]{1,46}$", var.cluster_name))
    error_message = "cluster_name must be lowercase letters, numbers, and hyphens, max 46 chars (feeds both the S3 backup bucket name and the '<name>-clickhouse-backup' IAM role, which has a 64-char limit)."
  }
}

variable "aws_profile" {
  description = "AWS CLI profile used for EKS token exec auth (null = default credentials)"
  type        = string
  default     = null
}

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
  description = "Instance type for ClickHouse nodes — ARM/Graviton local-NVMe family (i8g/im4gn/i4g). Default i8g.4xlarge (16 vCPU / 128 GiB / ~3.75TB NVMe). If you change the size, also re-tune the CHI container resources + data volume size in manifests/20-clickhouse-chi.yaml (they are hand-sized to this instance)."
  type        = string
  default     = "i8g.4xlarge"
}

# NOTE: ClickHouse node count is NOT set as a count var. The blueprint creates one node group
# per (pool × AZ) and applies desired_size PER AZ, so ClickHouse node count = len(clickhouse_zones)
# (1 node per AZ, pinned in eks.tf). Replica count in the CHI must match len(clickhouse_zones).

variable "clickhouse_zones" {
  description = "AZs for the ClickHouse data pool = number of replicas (1 node per AZ). Subset of availability_zones. Currently 2 AZs (1×2) due to i8g capacity; add a 3rd AZ here + bump CHI replicasCount to scale to 3 replicas later."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "clickhouse_ami_type" {
  description = "EKS AMI type for the ClickHouse node pool. Must be ARM64 for i8g/Graviton (AL2023_ARM_64_STANDARD); switch to AL2023_x86_64_STANDARD only if using an x86 instance family."
  type        = string
  default     = "AL2023_ARM_64_STANDARD"
}

variable "bench_instance_type" {
  description = "Instance type for the dedicated load-generation (system-bench) node. Graviton, non-burstable. Runs clickhouse-benchmark pods and doubles as an SSM interactive-query box."
  type        = string
  default     = "c7g.2xlarge"
}

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

variable "backup_bucket_name" {
  description = "S3 bucket name for clickhouse-backup (must be globally unique). Empty = auto-name from cluster."
  type        = string
  default     = ""
}

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

variable "public_access_cidrs" {
  description = "CIDRs allowed to reach the EKS public API endpoint. Default is world-open — RESTRICT before production."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
