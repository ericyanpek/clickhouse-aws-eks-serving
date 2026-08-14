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

output "backup_role_arns" {
  description = "Per-cluster backup IRSA role ARNs, for deploy.sh to render the ServiceAccount annotation."
  value       = { for k, r in aws_iam_role.backup : k => r.arn }
}

output "clickhouse_namespace" {
  value = var.clickhouse_namespace
}

output "region" {
  value = var.region
}

output "clickhouse_cluster_names" {
  description = "Configured ClickHouse cluster keys, for deploy.sh to iterate."
  value       = keys(var.clickhouse_clusters)
}

output "clickhouse_cluster_config" {
  description = "Per-cluster render parameters, for deploy.sh to fill the manifest templates."
  value = {
    for k, v in var.clickhouse_clusters : k => {
      storage_profile      = v.storage_profile
      storage_class        = v.storage_profile == "ebs" ? "ck-${k}-gp3" : "local-storage"
      shards               = v.shards
      replicas             = v.replicas
      zones                = v.zones
      data_volume_size_gib = v.data_volume_size_gib
      clickhouse_image     = v.clickhouse_image
      keeper_image         = v.keeper_image
      cpu_request          = v.cpu_request
      memory_request       = v.memory_request
      enable_backup        = v.enable_backup
      namespace            = "ck-${k}"
    }
  }
}
