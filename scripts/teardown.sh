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

echo "==> terraform destroy (phase 1: in-cluster helm/k8s resources while API is still alive)"
cd terraform
# The helm/kubernetes providers require a reachable cluster API. Destroy those
# resources FIRST, before the EKS control plane is torn down, to avoid a hang.
terraform destroy \
  -target=helm_release.kube_prometheus_stack \
  -target=helm_release.local_static_provisioner \
  -target=kubernetes_namespace.monitoring \
  -target=kubernetes_storage_class.local \
  || echo "WARNING: targeted destroy of in-cluster resources had issues; continuing" >&2

echo "==> terraform destroy (phase 2: everything else, incl. EKS cluster)"
terraform destroy

echo "==> NOTE: S3 backup bucket has versioning; empty + delete manually if desired:"
echo "    aws s3 rb s3://\$(terraform output -raw backup_bucket) --force"
