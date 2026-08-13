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

output "ebs_comparison" {
  description = "Resolved side-by-side EBS comparison profile."
  value = {
    enabled          = var.enable_ebs_comparison
    instance_type    = var.ebs_comparison_instance_type
    storage_class    = var.enable_ebs_comparison ? kubernetes_storage_class.clickhouse_ebs_comparison[0].metadata[0].name : null
    volume_size_gib  = var.ebs_comparison_volume_size_gib
    iops             = var.ebs_comparison_iops
    throughput_mibps = var.ebs_comparison_throughput_mibps
  }
}

output "ebs_comparison_volume_size_gib" {
  description = "PVC size used when rendering the optional EBS comparison CHI."
  value       = var.ebs_comparison_volume_size_gib
}

output "ebs_comparison_replica_count" {
  description = "Replica count used when rendering the optional EBS CHI."
  value       = length(var.ebs_comparison_zones)
}

output "local_nvme_comparison" {
  description = "Resolved benchmark-only local-NVMe profile."
  value = {
    enabled        = var.enable_local_nvme_comparison
    instance_type  = var.local_nvme_comparison_instance_type
    replica_count  = length(var.local_nvme_comparison_zones) * var.local_nvme_comparison_nodes_per_zone
    zones          = var.local_nvme_comparison_zones
    nodes_per_zone = var.local_nvme_comparison_nodes_per_zone
  }
}

output "local_nvme_comparison_replica_count" {
  description = "Replica count used when rendering the benchmark-only local-NVMe CHI."
  value       = length(var.local_nvme_comparison_zones) * var.local_nvme_comparison_nodes_per_zone
}
