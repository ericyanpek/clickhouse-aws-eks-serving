# Blueprint pin (v0.5.7) and operator_version (0.27.1) are coupled — bump both together after re-validating.
module "operator" {
  source = "github.com/Altinity/terraform-aws-eks-clickhouse//clickhouse-operator?ref=v0.5.7"

  depends_on = [module.eks]

  clickhouse_operator_namespace = "kube-system"
  clickhouse_operator_version   = var.operator_version
}
