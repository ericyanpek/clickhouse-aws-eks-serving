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
# NOTE: i4i instance-store NVMe must be formatted + mounted under /mnt/disks
# BEFORE this is useful — AL2023 does not auto-mount instance store. See README
# "Preparing i4i NVMe". On a fresh node with empty /mnt/disks, no PVs appear and
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
    nodeSelector = { workload = "clickhouse" }
    tolerations = [{
      key      = "dedicated"
      operator = "Equal"
      value    = "clickhouse"
      effect   = "NoSchedule"
    }]
  })]
}
