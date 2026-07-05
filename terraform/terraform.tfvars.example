# ── User MUST confirm these before `terraform apply` ──────────────────────────
region = "us-east-1"
# AZs chosen to AVOID us-east-1a: i8g.4xlarge had InsufficientInstanceCapacity there (2026-07).
# 1 node per AZ × 3 AZs = 3 ClickHouse nodes (1 shard × 3 replicas). Keeper/system likewise 1/AZ.
availability_zones = ["us-east-1b", "us-east-1c", "us-east-1d"]
cluster_name       = "clickhouse-eks"
cluster_version    = "1.34"

# ClickHouse nodes: ARM/Graviton local-NVMe. 1 shard × 3 replicas (one node per AZ; scale-up first).
# i8g.4xlarge = 16 vCPU / 128 GiB / ~3.75TB NVMe. Size chosen for compression + headroom;
# bump to i8g.8xlarge/12xlarge for load testing (then re-tune CHI resources + data volume size).
# Node COUNT is derived from AZ count (see eks.tf), not a variable.
clickhouse_instance_type = "i8g.4xlarge"
clickhouse_ami_type      = "AL2023_ARM_64_STANDARD"

# Pinned component versions (see docs/clickhouse-on-eks-research.md)
operator_version = "0.27.1"

# Backup bucket — MUST be globally unique. Leave empty to auto-name "<cluster>-ch-backups".
backup_bucket_name = ""

enable_monitoring = true
# grafana_admin_password = "set-me"   # uncomment and set, or change after first login

# SECURITY: default is world-open. Restrict to your office/VPN CIDR before production.
public_access_cidrs = ["0.0.0.0/0"]
