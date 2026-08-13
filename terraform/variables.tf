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

variable "kube_api_endpoint_override" {
  description = "Optional Kubernetes API endpoint override, used for a local SSM private-endpoint tunnel. Empty preserves the normal EKS endpoint."
  type        = string
  default     = ""
}

variable "kube_api_tls_server_name" {
  description = "TLS server name for kube_api_endpoint_override. Required when tunneling to an EKS endpoint through localhost."
  type        = string
  default     = ""
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

variable "enable_local_nvme" {
  description = "Create the existing local-NVMe ClickHouse node pool. Defaults to true; set false only for an EBS-only benchmark that reuses historical NVMe results."
  type        = bool
  default     = true
}

variable "enable_local_nvme_comparison" {
  description = "Append a benchmark-only local-NVMe node pool without changing the existing production-oriented local-NVMe pool or shifting current node-group indexes."
  type        = bool
  default     = false
}

variable "local_nvme_comparison_zones" {
  description = "One to three distinct AZs for the benchmark-only local-NVMe profile. A single AZ is a performance-only fallback and must not be presented as an HA result."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]

  validation {
    condition = (
      length(var.local_nvme_comparison_zones) >= 1 &&
      length(var.local_nvme_comparison_zones) <= 3 &&
      length(distinct(var.local_nvme_comparison_zones)) == length(var.local_nvme_comparison_zones)
    )
    error_message = "local_nvme_comparison_zones must contain one to three distinct availability zones."
  }
}

variable "local_nvme_comparison_nodes_per_zone" {
  description = "Benchmark-only local-NVMe nodes per selected AZ. Use 1 for cross-AZ comparison; 2 in one AZ is a performance-only capacity fallback."
  type        = number
  default     = 1

  validation {
    condition     = contains([1, 2], var.local_nvme_comparison_nodes_per_zone)
    error_message = "local_nvme_comparison_nodes_per_zone must be 1 or 2."
  }
}

variable "local_nvme_comparison_instance_type" {
  description = "Instance type for the benchmark-only local-NVMe profile."
  type        = string
  default     = "i8g.4xlarge"
}

# NOTE: ClickHouse node count is NOT set as a count var. The blueprint creates one node group
# per (pool × AZ) and applies desired_size PER AZ, so ClickHouse node count = len(clickhouse_zones)
# (1 node per AZ, pinned in eks.tf). Replica count in the CHI must match len(clickhouse_zones).

variable "clickhouse_zones" {
  description = "Exactly 3 AZs for the fixed 1-shard x 3-replica ClickHouse data pool (1 node per AZ). These must also be present in availability_zones."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]

  validation {
    condition     = length(var.clickhouse_zones) == 3 && length(distinct(var.clickhouse_zones)) == 3
    error_message = "This design requires exactly 3 distinct ClickHouse availability zones for its 1-shard x 3-replica topology."
  }
}

variable "clickhouse_ami_type" {
  description = "EKS AMI type for the ClickHouse node pool. Must be ARM64 for i8g/Graviton (AL2023_ARM_64_STANDARD); switch to AL2023_x86_64_STANDARD only if using an x86 instance family."
  type        = string
  default     = "AL2023_ARM_64_STANDARD"
}

variable "enable_ebs_comparison" {
  description = "Add a separate R8g ClickHouse node pool and tuned gp3 StorageClass for comparison. The existing local-NVMe cluster remains unchanged when enable_local_nvme is true."
  type        = bool
  default     = false
}

variable "ebs_comparison_zones" {
  description = "Two or three distinct AZs for the optional EBS profile. Use two to reproduce the historical 1x2 NVMe test basis; the default remains 1x3."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]

  validation {
    condition = (
      length(var.ebs_comparison_zones) >= 2 &&
      length(var.ebs_comparison_zones) <= 3 &&
      length(distinct(var.ebs_comparison_zones)) == length(var.ebs_comparison_zones)
    )
    error_message = "ebs_comparison_zones must contain two or three distinct availability zones."
  }
}

variable "ebs_comparison_instance_type" {
  description = "Instance type for the optional EBS comparison pool. r8g.4xlarge matches i8g.4xlarge at 16 vCPU and 128 GiB without paying for unused instance-store capacity."
  type        = string
  default     = "r8g.4xlarge"
}

variable "ebs_comparison_volume_size_gib" {
  description = "Size in GiB of each ClickHouse EBS data volume in the comparison cluster."
  type        = number
  default     = 3400

  validation {
    condition     = var.ebs_comparison_volume_size_gib >= 100
    error_message = "ebs_comparison_volume_size_gib must be at least 100 GiB."
  }

  validation {
    condition     = var.ebs_comparison_volume_size_gib <= 16384
    error_message = "ebs_comparison_volume_size_gib must not exceed the gp3 maximum of 16384 GiB."
  }
}

variable "ebs_comparison_iops" {
  # 20000 matches the r8g.4xlarge SUSTAINED EBS baseline. 40000 is that instance's
  # BURST ceiling, reachable only for 30 minutes per 24 hours, so provisioning it
  # buys capability the instance cannot sustain. Measured 2026-08-12: peak 14,993
  # and 9,701 IOPS under read-heavy ClickBench, and only 1,415/1,428 during a
  # merge. At the observed 120-157 KiB per I/O, saturating 1,250 MiB/s needs about
  # 8,200 IOPS, so this workload is throughput-bound, not IOPS-bound.
  description = "Provisioned gp3 IOPS per comparison volume. 20000 matches the r8g.4xlarge sustained EBS baseline; its 40000 burst ceiling is only available 30 minutes per 24 hours."
  type        = number
  default     = 20000

  validation {
    condition     = var.ebs_comparison_iops >= 3000 && var.ebs_comparison_iops <= 80000
    error_message = "ebs_comparison_iops must be between 3000 and the current gp3 maximum of 80000."
  }
}

variable "ebs_comparison_throughput_mibps" {
  # Hold at 1250 and do NOT reduce this. The instance channel is 625 MB/s
  # sustained (= 596.05 MiB/s) and 1250 MB/s burst (= 1192.09 MiB/s) -- note AWS
  # states instance throughput in decimal MB/s while gp3 is provisioned in MiB/s.
  # Merge-window device counters from 2026-08-12 put EBS p95 at 1,130-1,193 MiB/s
  # with peak utilization at 102%, so dropping to 1000 MiB/s would clip sustained
  # merge throughput and further extend a merge already 48% slower than local NVMe.
  description = "Provisioned gp3 throughput in MiB/s per comparison volume. Hold at 1250: measured merge p95 reaches 1,130-1,193 MiB/s, so reducing this clips merge throughput."
  type        = number
  default     = 1250

  validation {
    condition     = var.ebs_comparison_throughput_mibps >= 125 && var.ebs_comparison_throughput_mibps <= 2000
    error_message = "ebs_comparison_throughput_mibps must be between 125 and the current gp3 maximum of 2000 MiB/s."
  }
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
