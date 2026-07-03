# gp3 for Keeper (and any non-CH PVC). WaitForFirstConsumer so the volume is
# created in the same AZ as the scheduled pod.
resource "kubernetes_storage_class" "gp3" {
  metadata {
    name = "gp3-encrypted"
  }
  storage_provisioner    = "ebs.csi.aws.com"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  reclaim_policy         = "Delete"
  parameters = {
    type      = "gp3"
    encrypted = "true"
    fsType    = "ext4"
  }
}

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
resource "helm_release" "local_static_provisioner" {
  depends_on = [module.eks, kubernetes_storage_class.local]

  name       = "local-static-provisioner"
  repository = "https://kubernetes-sigs.github.io/sig-storage-local-static-provisioner"
  chart      = "local-static-provisioner"
  version    = "1.7.0" # user confirms latest compatible at apply time
  namespace  = "kube-system"

  values = [yamlencode({
    classes = [{
      name                = "local-storage"
      hostDir             = "/mnt/disks"
      mountDir            = "/mnt/disks"
      blockCleanerCommand = ["/scripts/shred.sh", "2"]
    }]
    daemonset = {
      nodeSelector = { workload = "clickhouse" }
      tolerations = [{
        key      = "dedicated"
        operator = "Equal"
        value    = "clickhouse"
        effect   = "NoSchedule"
      }]
    }
  })]
}
