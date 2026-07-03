output "configure_kubectl" {
  description = "Run this to configure kubectl access"
  value       = "aws eks --region ${var.region} update-kubeconfig --name ${module.eks.cluster_name}"
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "backup_bucket" {
  value = aws_s3_bucket.backup.id
}

output "backup_role_arn" {
  description = "Annotate the clickhouse-backup ServiceAccount with this role ARN"
  value       = aws_iam_role.backup.arn
}

output "clickhouse_namespace" {
  value = var.clickhouse_namespace
}
