# ── User MUST confirm these before `terraform apply` ──────────────────────────
region             = "us-east-1"
availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"]
cluster_name       = "clickhouse-eks"
cluster_version    = "1.34"

# ClickHouse nodes: ARM/Graviton local-NVMe. 3 nodes = 1 shard × 3 replicas (scale-up first).
# i8g.4xlarge = 16 vCPU / 128 GiB / ~3.75TB NVMe. Size chosen for compression + headroom;
# bump to i8g.8xlarge/12xlarge for load testing (then re-tune CHI resources + data volume size).
clickhouse_instance_type = "i8g.4xlarge"
clickhouse_ami_type      = "AL2023_ARM_64_STANDARD"
clickhouse_node_count    = 3

# Pinned component versions (see docs/clickhouse-on-eks-research.md)
operator_version = "0.27.1"

# Backup bucket — MUST be globally unique. Leave empty to auto-name "<cluster>-ch-backups".
backup_bucket_name = ""

enable_monitoring = true
# grafana_admin_password = "set-me"   # uncomment and set, or change after first login

# SECURITY: default is world-open. Restrict to your office/VPN CIDR before production.
public_access_cidrs = ["0.0.0.0/0"]
