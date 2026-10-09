locals {
  # Resolve omitted per-cluster zones from the deployment's region/AZ selection.
  clickhouse_clusters = {
    for name, c in var.clickhouse_clusters :
    name => merge(c, { zones = c.zones != null ? c.zones : var.availability_zones })
  }
}

# Cross-variable checks use preconditions to remain compatible with Terraform 1.5.
# A check block would only warn; these must prevent deployment.
# deploy.sh explicitly targets this guard in phase 1. Do not make the whole EKS
# module depend on it: doing so can defer unrelated data sources during upgrades.
resource "terraform_data" "cluster_config" {
  lifecycle {
    precondition {
      condition     = alltrue([for az in var.availability_zones : can(regex("^${var.region}[a-z]$", az))])
      error_message = "availability_zones must be standard AZ names in the configured region."
    }
    precondition {
      condition = alltrue(flatten([
        for c in values(local.clickhouse_clusters) :
        [for az in c.zones : contains(var.availability_zones, az)]
      ]))
      error_message = "Every cluster zone must belong to availability_zones."
    }
  }
}
