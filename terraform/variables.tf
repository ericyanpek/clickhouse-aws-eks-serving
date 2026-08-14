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
    condition     = can(regex("^[a-z0-9-]{1,40}$", var.cluster_name))
    error_message = "cluster_name must be lowercase letters, numbers, and hyphens, max 40 chars. It feeds the S3 backup bucket name and the per-cluster '<name>-ck-<cluster>-backup' IAM role, which has a 64-char limit."
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

  validation {
    # Cluster keys feed the IAM role name "<cluster_name>-ck-<key>-backup", capped by
    # IAM at 64 characters. A validation block may only reference its own variable, so
    # the combined length is asserted as a precondition in irsa.tf; this bounds the
    # key's own contribution so that cluster_name keeps its documented 40-char budget.
    condition     = alltrue([for k, v in var.clickhouse_clusters : length(k) <= 20])
    error_message = "Cluster keys must be 20 characters or fewer: they feed the IAM role name '<cluster_name>-ck-<key>-backup', which IAM caps at 64 characters."
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
