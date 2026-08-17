# NOTE: gp3-encrypted StorageClass is already created (as cluster default) by the
# blueprint //eks submodule (eks/addons.tf). Keeper's CHK references it by name.
# Do NOT redefine it here — a duplicate metadata.name collides at apply.

# One gp3 class per ebs cluster, so each cluster can run a different tier.
# The 20k IOPS / 1250 MiB/s default comes from measurement: observed peak was
# 14,993 IOPS, and at 120-157 KiB per I/O saturating 1250 MiB/s needs only about
# 8,200 IOPS -- this workload is throughput-bound, not IOPS-bound. 20k also equals
# the r8g.4xlarge sustained EBS baseline; its 40k figure is a burst ceiling
# available only 30 minutes per 24 hours. Throughput must NOT be reduced: during a
# merge, p95 reached 1,130-1,193 MiB/s at 102% device utilization.
resource "kubernetes_storage_class" "clickhouse_gp3" {
  for_each = local.ebs_clusters

  metadata {
    name = "ck-${each.key}-gp3"
  }

  storage_provisioner = "ebs.csi.aws.com"

  parameters = {
    encrypted  = "true"
    fsType     = "ext4"
    type       = "gp3"
    iops       = tostring(each.value.gp3_iops)
    throughput = tostring(each.value.gp3_throughput_mibps)
  }

  # Retain rather than Delete: the whole point of this profile is that a volume
  # outlives its node. Delete would discard data the moment a PVC is removed,
  # which is exactly the local-NVMe failure mode this profile exists to avoid.
  reclaim_policy = "Retain"
  # WaitForFirstConsumer binds the volume in the AZ where the pod is scheduled,
  # matching the AZ-scoped nature of a gp3 volume.
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
}

# local-storage class for ClickHouse instance-store NVMe, used when
# storage_profile = "local-nvme". No provisioner — PVs are published by the
# local-static-provisioner DaemonSet below.
resource "kubernetes_storage_class" "local" {
  count = local.has_local_nvme ? 1 : 0

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
  count = local.has_local_nvme ? 1 : 0

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
