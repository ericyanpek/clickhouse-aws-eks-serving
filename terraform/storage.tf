# NOTE: gp3-encrypted StorageClass is already created (as cluster default) by the
# blueprint //eks submodule (eks/addons.tf). Keeper's CHK references it by name.
# Do NOT redefine it here — a duplicate metadata.name collides at apply.

# local-storage class for ClickHouse instance-store NVMe. No provisioner —
# PVs are published by the local-static-provisioner DaemonSet below.
resource "kubernetes_storage_class" "local" {
  metadata {
    name = "local-storage"
  }
  storage_provisioner = "kubernetes.io/no-provisioner"
  volume_binding_mode = "WaitForFirstConsumer"
  reclaim_policy      = "Delete"
}

# sig-storage local-static-provisioner: discovers NVMe under /mnt/disks and
# publishes them as `local` PVs on the local-storage class.
# NOTE: i8g instance-store NVMe must be formatted + mounted under /mnt/disks
# BEFORE this is useful — AL2023 does not auto-mount instance store. See README
# "Preparing NVMe Disks". On a fresh node with empty /mnt/disks, no PVs appear and
# ClickHouse PVCs stay Pending.
resource "helm_release" "local_static_provisioner" {
  depends_on = [module.eks, kubernetes_storage_class.local]

  name       = "local-static-provisioner"
  repository = "https://kubernetes-sigs.github.io/sig-storage-local-static-provisioner"
  chart      = "local-static-provisioner"
  version    = "2.8.0" # verified published version; user confirms latest compatible at apply time
  namespace  = "kube-system"

  # v2.x schema: nodeSelector + tolerations are TOP-LEVEL (no `daemonset` wrapper).
  values = [yamlencode({
    classes = [{
      name                = "local-storage"
      hostDir             = "/mnt/disks"
      mountDir            = "/mnt/disks"
      blockCleanerCommand = ["/scripts/shred.sh", "2"]
    }]
    nodeSelector = { storage = "local-nvme" }
    tolerations = [{
      key      = "dedicated"
      operator = "Equal"
      value    = "clickhouse"
      effect   = "NoSchedule"
    }]
  })]
}

# Optional EBS comparison class. It is deliberately separate from the blueprint's
# default gp3-encrypted class, which leaves gp3 at its 3000 IOPS / 125 MiB/s defaults.
# The selected defaults match the aggregate EBS ceiling of r8g.4xlarge so the first
# comparison measures EBS architecture rather than an artificially under-provisioned volume.
resource "kubernetes_storage_class" "clickhouse_ebs_comparison" {
  count = var.enable_ebs_comparison ? 1 : 0

  lifecycle {
    precondition {
      condition     = var.ebs_comparison_throughput_mibps <= var.ebs_comparison_iops * 0.25
      error_message = "gp3 throughput in MiB/s must not exceed 0.25 times the provisioned IOPS."
    }
  }

  metadata {
    name = "clickhouse-ebs-gp3"
  }

  storage_provisioner = "ebs.csi.aws.com"

  parameters = {
    encrypted  = "true"
    fsType     = "ext4"
    type       = "gp3"
    iops       = tostring(var.ebs_comparison_iops)
    throughput = tostring(var.ebs_comparison_throughput_mibps)
  }

  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
}
