#!/usr/bin/env bash
set -euo pipefail
# Deploy ClickHouse on EKS. Run from repo root. Assumes AWS creds are configured.
cd "$(dirname "$0")/.."

echo "==> [1/5] terraform apply (creates EKS, operator, storage, monitoring, S3, IRSA)"
cd terraform
terraform init
terraform apply
BUCKET=$(terraform output -raw backup_bucket)
ROLE_ARN=$(terraform output -raw backup_role_arn)
REGION=$(terraform output -raw configure_kubectl | grep -oE 'region [a-z0-9-]+' | awk '{print $2}')
eval "$(terraform output -raw configure_kubectl)"
cd ..

echo "==> [2/5] waiting for operator to be ready"
# Blueprint installs the operator as helm release 'altinity-clickhouse-operator' in kube-system.
kubectl -n kube-system rollout status deploy/altinity-clickhouse-operator --timeout=180s || true

echo "==> [3/5] substituting backup role ARN and bucket into manifests"
tmpdir=$(mktemp -d)
cp manifests/*.yaml "$tmpdir/"
sed -i.bak "s|REPLACE_WITH_BACKUP_ROLE_ARN|$ROLE_ARN|g" "$tmpdir/30-backup-cronjob.yaml"
sed -i.bak "s|REPLACE_WITH_BUCKET|$BUCKET|g; s|S3_REGION: \"us-east-1\"|S3_REGION: \"$REGION\"|g" "$tmpdir/30-backup-cronjob.yaml"

# Fail-fast if any placeholder survived substitution (would silently break IRSA/backup).
if grep -q "REPLACE_WITH" "$tmpdir/30-backup-cronjob.yaml"; then
  echo "ERROR: unsubstituted REPLACE_WITH placeholder remains in 30-backup-cronjob.yaml" >&2
  exit 1
fi

echo "==> [4/5] applying manifests in order"
kubectl apply -f "$tmpdir/00-namespace.yaml"
# The clickhouse-backup ServiceAccount + ConfigMap must exist BEFORE the CHI, because the
# CHI podTemplate sets serviceAccountName: clickhouse-backup and the sidecar reads the ConfigMap.
kubectl apply -f "$tmpdir/30-backup-cronjob.yaml"
kubectl apply -f "$tmpdir/10-keeper-chk.yaml"
kubectl -n clickhouse wait --for=condition=Ready pod -l app=clickhouse-keeper --timeout=300s || true
kubectl apply -f "$tmpdir/20-clickhouse-chi.yaml"
kubectl apply -f "$tmpdir/40-grafana-dashboard.yaml"

echo "==> [5/5] done. Watch rollout with: kubectl -n clickhouse get chi,chk,pods -w"
