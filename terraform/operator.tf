module "operator" {
  source = "github.com/Altinity/terraform-aws-eks-clickhouse//clickhouse-operator?ref=v0.5.7"

  depends_on = [module.eks]

  clickhouse_operator_namespace = "kube-system"
  clickhouse_operator_version   = var.operator_version
}
