# SSM access for EKS nodes.
#
# WHY: the blueprint's //eks node role has only CNI/ECR/WorkerNode policies — no SSM.
# Attaching AmazonSSMManagedInstanceCore lets you `aws ssm start-session` onto any node
# (in particular the system-bench node) for interactive ClickHouse queries, without SSH,
# open ports, or a bastion. Harmless on the other node groups.
#
# The node role is created inside the blueprint module as "${cluster_name}-eks-node-role";
# we look it up by name and attach the AWS-managed SSM policy in our wrapper.

data "aws_iam_role" "eks_node" {
  name       = "${var.cluster_name}-eks-node-role"
  depends_on = [module.eks]
}

resource "aws_iam_role_policy_attachment" "node_ssm" {
  role       = data.aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
