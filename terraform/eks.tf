module "eks" {
  source = "github.com/Altinity/terraform-aws-eks-clickhouse//eks?ref=v0.5.7"

  region             = var.region
  cluster_name       = var.cluster_name
  cluster_version    = var.cluster_version
  cidr               = var.vpc_cidr
  availability_zones = var.availability_zones
  public_cidr        = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
  private_cidr       = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]

  # Blueprint requires the community EKS module defaults; keep NAT + private nodes.
  enable_nat_gateway = true

  autoscaler_version = "1.34.0" # keep major.minor in sync with cluster_version (1.34) when bumping

  autoscaler_replicas = 1
  public_access_cidrs = var.public_access_cidrs
  tags                = {}

  # IMPORTANT — blueprint node-pool semantics (verified in v0.5.7 eks/main.tf):
  # the module creates ONE node group per (pool × zone), and desired/min/max are applied
  # PER node group (per AZ), NOT as a pool total. So a pool spanning 3 AZs with desired=3
  # yields 3×3 = 9 nodes. To get "1 node per AZ" set desired=min=max=1 with 3 zones.
  # Also: ami_type MUST be set explicitly — the blueprint default is AL2_x86_64, which EKS
  # rejects on k8s >= 1.33 ("AMI Type AL2_x86_64 is only supported for 1.32 or earlier").
  node_pools = [
    {
      name          = "clickhouse"
      instance_type = var.clickhouse_instance_type
      ami_type      = var.clickhouse_ami_type # ARM64 for i8g/Graviton
      disk_size     = 50                      # root EBS; data lives on instance-store NVMe
      desired_size  = 1                       # PER AZ → len(clickhouse_zones) × 1 nodes (= CHI replicasCount)
      min_size      = 1
      max_size      = 2                    # per-AZ headroom for node replacement; new i8g nodes = empty local NVMe, replica rebuild required
      zones         = var.clickhouse_zones # 2 AZs now (1×2) due to i8g capacity; keeper/system stay on all 3 AZs
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
      ami_type      = "AL2023_x86_64_STANDARD" # explicit — blueprint default AL2_x86_64 fails on 1.34
      disk_size     = 20
      desired_size  = 1 # PER AZ → 3 zones × 1 = 3 system nodes (operator/monitoring/autoscaler)
      min_size      = 1
      max_size      = 2
      zones         = var.availability_zones
      labels        = { "workload" = "system" }
    },
    {
      name          = "system-keeper"
      instance_type = "t3.medium"
      ami_type      = "AL2023_x86_64_STANDARD" # explicit — blueprint default AL2_x86_64 fails on 1.34
      disk_size     = 20
      desired_size  = 1 # PER AZ → 3 zones × 1 = 3 Keeper nodes (odd quorum across AZs)
      min_size      = 1
      max_size      = 1
      zones         = var.availability_zones
      labels        = { "workload" = "keeper" }
      taints = [{
        key    = "dedicated"
        value  = "keeper"
        effect = "NO_SCHEDULE"
      }]
    },
    {
      # Dedicated, non-burstable load-generation node. Runs clickhouse-benchmark pods
      # (pinned via nodeSelector workload=bench + toleration) so the benchmark client
      # never competes with ClickHouse for CPU/page-cache. Single AZ (no HA needed).
      # Also usable as an SSM interactive-query box (node role gets SSM policy in irsa.tf).
      name          = "system-bench"
      instance_type = var.bench_instance_type # c7g.2xlarge = 8 vCPU / 16 GiB, Graviton, non-burstable
      ami_type      = "AL2023_ARM_64_STANDARD"
      disk_size     = 50
      desired_size  = 1
      min_size      = 1
      max_size      = 1
      zones         = [var.availability_zones[0]] # single AZ (1a) — near a ClickHouse replica
      labels        = { "workload" = "bench" }
      taints = [{
        key    = "dedicated"
        value  = "bench"
        effect = "NO_SCHEDULE"
      }]
    }
  ]
}
