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
  description = "Instance type for ClickHouse nodes — MUST be a local-NVMe family (i4i/i3). Default i4i.xlarge."
  type        = string
  default     = "i4i.xlarge"
}

variable "clickhouse_node_count" {
  description = "Number of ClickHouse nodes = shards × replicas. Design is 2×2 = 4."
  type        = number
  default     = 4
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
