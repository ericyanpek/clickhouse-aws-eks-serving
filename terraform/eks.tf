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
