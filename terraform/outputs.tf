output "configure_kubectl" {
  description = "Run this to configure kubectl access"
  # Include --profile when set, matching the provider exec auth in providers.tf —
  # otherwise deploy.sh writes a kubeconfig using the wrong (default) credentials.
  value = var.aws_profile != null ? "aws eks --region ${var.region} update-kubeconfig --name ${module.eks.cluster_name} --profile ${var.aws_profile}" : "aws eks --region ${var.region} update-kubeconfig --name ${module.eks.cluster_name}"
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

output "region" {
  value = var.region
}
