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
