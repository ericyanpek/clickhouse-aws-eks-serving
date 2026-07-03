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

echo "==> terraform destroy"
cd terraform
terraform destroy

echo "==> NOTE: S3 backup bucket has versioning; empty + delete manually if desired:"
echo "    aws s3 rb s3://\$(terraform output -raw backup_bucket) --force"
