# The upstream module creates the node role internally but does not expose it.
# Naming is defined at .terraform/modules/eks/eks/iam.tf:45 as
# "${cluster_name}-eks-node-role". terraform/ssm.tf already relies on this same
# convention, so this reuses an established assumption rather than adding one.
data "aws_iam_role" "node" {
  name       = "${var.cluster_name}-eks-node-role"
  depends_on = [module.eks]
}

# The node security group the upstream module creates for its own node groups. Self
# managed node groups MUST join it too.
#
# Omitting a security group does not fail: AWS silently places the node group in the
# cluster's default security group instead. Both groups only allow ingress from
# themselves, so nodes in one cannot reach pods in the other -- and because CoreDNS
# runs on the upstream system nodes, every self-managed pod loses DNS. The symptom is
# a Keeper that cannot resolve its raft peers and crash-loops, several layers away
# from the missing attribute.
#
# The group name carries a random suffix, so it is matched by the cluster ownership
# tag plus the name prefix; the tag alone also matches the cluster security group.
# The precondition guarantees exactly one match rather than silently taking the first.
data "aws_security_group" "node" {
  filter {
    name   = "tag:kubernetes.io/cluster/${var.cluster_name}"
    values = ["owned"]
  }

  filter {
    name   = "group-name"
    values = ["${var.cluster_name}-node-*"]
  }

  lifecycle {
    postcondition {
      condition     = can(regex("^${var.cluster_name}-node-", self.name))
      error_message = "Resolved security group ${self.name} is not the upstream node group. Self-managed nodes must join the same group as the upstream nodes, or they lose DNS."
    }
  }

  depends_on = [module.eks]
}

# aws_eks_node_group has no security-group argument: the only way to place a managed
# node group in a specific security group is through a launch template. Without one,
# AWS silently uses the cluster's default group, which cannot reach the upstream nodes
# where CoreDNS runs.
#
# disk_size on the node group and a launch template are mutually exclusive, so the
# root volume is defined here too.
resource "aws_launch_template" "node" {
  name_prefix            = "${var.cluster_name}-ck-node-"
  update_default_version = true
  vpc_security_group_ids = [data.aws_security_group.node.id]

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = 50
      volume_type = "gp3"
      encrypted   = true
    }
  }

  # EKS reads the AMI and bootstrap from the node group's ami_type, so the template
  # deliberately sets neither.
  tag_specifications {
    resource_type = "instance"
    tags          = { "Name" = "${var.cluster_name}-clickhouse-node" }
  }

  lifecycle {
    create_before_destroy = true
  }
}

# One private subnet per AZ. Single-subnet pinning is what allows a gp3 volume to
# be reattached: the volume is AZ-scoped, so if a node group spanned several
# subnets a replacement node could land in a different AZ and fail to attach.
#
# Scoped to this cluster's VPC on purpose. Filtering by name tag alone would also
# match an identically named subnet in another VPC in the same account, and the
# extra ID would silently widen the node group across AZs -- defeating the very
# pinning this lookup exists to guarantee. The precondition then turns both the
# zero-match and multi-match cases into a plan-time error naming the AZ, instead
# of an opaque "subnet_ids required" from the EKS API at apply time.
data "aws_subnets" "private_by_az" {
  for_each = toset(var.availability_zones)

  filter {
    name   = "vpc-id"
    values = [data.aws_eks_cluster.this.vpc_config[0].vpc_id]
  }

  filter {
    name   = "tag:Name"
    values = ["${var.cluster_name}-vpc-private-${each.key}"]
  }

  lifecycle {
    postcondition {
      condition     = length(self.ids) == 1
      error_message = "Expected exactly one private subnet named ${var.cluster_name}-vpc-private-${each.key}, found ${length(self.ids)}. Node groups must be pinned to a single subnet so an AZ-scoped gp3 volume can be reattached."
    }
  }

  depends_on = [module.eks]
}

resource "aws_eks_node_group" "clickhouse" {
  for_each = local.ck_node_groups

  cluster_name    = module.eks.cluster_name
  node_group_name = "ck-${each.key}"
  node_role_arn   = data.aws_iam_role.node.arn
  subnet_ids      = data.aws_subnets.private_by_az[each.value.az].ids
  instance_types  = [each.value.instance_type]
  ami_type        = "AL2023_ARM_64_STANDARD"

  # Carries the security group; the root volume is defined in the template.
  launch_template {
    id      = aws_launch_template.node.id
    version = aws_launch_template.node.latest_version
  }

  scaling_config {
    desired_size = each.value.nodes_per_az
    min_size     = each.value.nodes_per_az
    # One spare slot for a rolling replacement. On the ebs profile a replacement
    # node reattaches the original volume; on local-nvme it starts empty and needs
    # scripts/recover-local-replica.sh.
    max_size = each.value.nodes_per_az + 1
  }

  labels = {
    workload   = "clickhouse"
    storage    = each.value.storage
    ck-cluster = each.value.cluster # the CHI nodeSelector uses this to target its own pool
  }

  # Upstream added this taint automatically for pools named clickhouse*; self-managed
  # it must be explicit, or unrelated workloads land on the data nodes.
  taint {
    key    = "dedicated"
    value  = "clickhouse"
    effect = "NO_SCHEDULE"
  }

  tags = {
    # Without these two tags cluster-autoscaler does not recognize the node group.
    "k8s.io/cluster-autoscaler/enabled"             = "true"
    "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
  }

  lifecycle {
    # desired_size is adjusted by the autoscaler at runtime; Terraform must not
    # pull it back to the configured value on every apply.
    ignore_changes = [scaling_config[0].desired_size]
  }
}

resource "aws_eks_node_group" "keeper" {
  for_each = local.kp_node_groups

  cluster_name    = module.eks.cluster_name
  node_group_name = "kp-${each.key}"
  node_role_arn   = data.aws_iam_role.node.arn
  subnet_ids      = data.aws_subnets.private_by_az[each.value.az].ids
  instance_types  = [each.value.instance_type]
  ami_type        = "AL2023_ARM_64_STANDARD"

  launch_template {
    id      = aws_launch_template.node.id
    version = aws_launch_template.node.latest_version
  }

  scaling_config {
    desired_size = 1 # one Keeper per AZ, forming an odd cross-AZ quorum
    min_size     = 1
    max_size     = 1 # quorum membership is fixed; it must not autoscale
  }

  labels = {
    workload   = "keeper"
    ck-cluster = each.value.cluster
  }

  taint {
    key    = "dedicated"
    value  = "keeper"
    effect = "NO_SCHEDULE"
  }

  tags = {
    "k8s.io/cluster-autoscaler/enabled"             = "true"
    "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
  }
}
