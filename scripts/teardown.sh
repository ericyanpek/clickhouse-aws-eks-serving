#!/usr/bin/env bash
set -euo pipefail
# Ordered teardown. Deletes CH resources first so the operator releases PVs/LBs,
# then destroys AWS infra. Prevents orphaned EBS/ENI/LB charges.
cd "$(dirname "$0")/.."

echo "==> deleting ClickHouse + Keeper (operator cleans up PVCs/services)"
kubectl delete -f manifests/20-clickhouse-chi.yaml --ignore-not-found
kubectl delete -f manifests/10-keeper-chk.yaml --ignore-not-found
kubectl -n clickhouse delete pvc --all --ignore-not-found
sleep 20

echo "==> deleting backup resources + clickhouse namespace + nvme bootstrap"
kubectl delete -f manifests/30-backup-cronjob.yaml --ignore-not-found
kubectl delete namespace clickhouse --ignore-not-found
kubectl delete -f manifests/05-nvme-bootstrap.yaml --ignore-not-found

echo "==> terraform destroy (phase 1: in-cluster helm/k8s resources while API is still alive)"
cd terraform
# Capture this before removing the bucket from state so the operator gets an exact
# name to retain or delete later.
BACKUP_BUCKET=$(terraform output -raw backup_bucket)
[ -n "$BACKUP_BUCKET" ] || { echo "ERROR: could not read backup bucket from Terraform state" >&2; exit 1; }

# The helm/kubernetes providers require a reachable cluster API. Destroy those
# resources FIRST, before the EKS control plane is torn down, to avoid a hang.
terraform destroy \
  -target=helm_release.kube_prometheus_stack \
  -target=helm_release.local_static_provisioner \
  -target=kubernetes_namespace.monitoring \
  -target=kubernetes_storage_class.local \
  || echo "WARNING: targeted destroy of in-cluster resources had issues; continuing" >&2

# Retain the versioned backup bucket and all of its safety configuration. Terraform
# must stop managing these objects before the full destroy, otherwise destroy either
# fails on the non-empty bucket or removes configuration from the retained bucket.
echo "==> retaining S3 backup bucket outside Terraform state: $BACKUP_BUCKET"
for address in \
  aws_s3_bucket_public_access_block.backup \
  aws_s3_bucket_server_side_encryption_configuration.backup \
  aws_s3_bucket_versioning.backup \
  aws_s3_bucket.backup; do
  if terraform state list | grep -Fxq "$address"; then
    terraform state rm "$address"
  fi
done

echo "==> terraform destroy (phase 2: everything else, incl. EKS cluster)"
terraform destroy

echo "==> retained S3 backup bucket: s3://$BACKUP_BUCKET"
echo "    It is no longer managed by this Terraform state. Empty all object versions"
echo "    and delete it manually only after confirming the backups are no longer needed."
