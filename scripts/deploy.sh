#!/usr/bin/env bash
set -euo pipefail
# Deploy ClickHouse on EKS. Run from repo root. Assumes AWS creds are configured.
cd "$(dirname "$0")/.."

cd terraform
terraform init

# Two-phase apply. The kubernetes/helm providers are configured to talk to the EKS
# API endpoint, which does not exist until the cluster is built. Doing everything in
# ONE apply risks those providers trying to connect to a not-yet-ready cluster
# (operator/monitoring/storage helm releases fail or hang mid-apply). So:
#   Phase 1: build ONLY the AWS infra (VPC, EKS, node groups, S3, IRSA) — no in-cluster resources.
#   Phase 2: full apply — now the cluster is ACTIVE, so helm/kubernetes resources install cleanly.
# -target is a deliberate, documented use here (not a workaround for a broken graph).
echo "==> [1/7] terraform apply — phase 1: AWS infra only (EKS/VPC/nodegroups/S3/IRSA)"
terraform apply -input=false -auto-approve \
  -target=module.eks \
  -target=aws_s3_bucket.backup \
  -target=aws_s3_bucket_versioning.backup \
  -target=aws_s3_bucket_server_side_encryption_configuration.backup \
  -target=aws_s3_bucket_public_access_block.backup \
  -target=aws_iam_role.backup \
  -target=aws_iam_role_policy.backup_s3

echo "==> [2/7] terraform apply — phase 2: in-cluster helm/k8s resources (operator/monitoring/storage)"
# Cluster is ACTIVE now; the kubernetes/helm providers can reach it. Full apply installs
# the operator, kube-prometheus-stack, and the local-storage StorageClass + provisioner.
terraform apply -input=false -auto-approve

BUCKET=$(terraform output -raw backup_bucket)
ROLE_ARN=$(terraform output -raw backup_role_arn)
REGION=$(terraform output -raw region)
[ -n "$REGION" ] || { echo "ERROR: could not read region from terraform output" >&2; exit 1; }
eval "$(terraform output -raw configure_kubectl)"
cd ..

echo "==> [3/7] waiting for operator to be ready"
# Blueprint installs the operator as helm release 'altinity-clickhouse-operator' in kube-system.
kubectl -n kube-system rollout status deploy/altinity-clickhouse-operator --timeout=180s \
  || echo "WARNING: operator rollout did not complete in time — CHI apply may fail" >&2

echo "==> [4/7] substituting backup role ARN and bucket into manifests"
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
cp manifests/*.yaml "$tmpdir/"
sed -i.bak "s|REPLACE_WITH_BACKUP_ROLE_ARN|$ROLE_ARN|g" "$tmpdir/30-backup-cronjob.yaml"
sed -i.bak "s|REPLACE_WITH_BUCKET|$BUCKET|g; s|S3_REGION: \"us-east-1\"|S3_REGION: \"$REGION\"|g" "$tmpdir/30-backup-cronjob.yaml"

# Fail-fast if any placeholder survived substitution (would silently break IRSA/backup).
if grep -q "REPLACE_WITH" "$tmpdir/30-backup-cronjob.yaml"; then
  echo "ERROR: unsubstituted REPLACE_WITH placeholder remains in 30-backup-cronjob.yaml" >&2
  exit 1
fi

echo "==> [5/7] formatting + mounting i8g NVMe on ClickHouse nodes"
# i8g instance-store NVMe is not auto-mounted by AL2023; this DaemonSet mounts it under
# /mnt/disks so the local-static-provisioner can publish local PVs. Without it the
# ClickHouse PVCs stay Pending. Runs in kube-system, targets workload=clickhouse nodes.
kubectl apply -f "$tmpdir/05-nvme-bootstrap.yaml"
kubectl -n kube-system rollout status ds/nvme-bootstrap --timeout=180s \
  || echo "WARNING: nvme-bootstrap DaemonSet not ready — ClickHouse PVCs may stay Pending" >&2

echo "==> [6/7] applying manifests in order"
kubectl apply -f "$tmpdir/00-namespace.yaml"
# The clickhouse-backup ServiceAccount + ConfigMap must exist BEFORE the CHI, because the
# CHI podTemplate sets serviceAccountName: clickhouse-backup and the sidecar reads the ConfigMap.
kubectl apply -f "$tmpdir/30-backup-cronjob.yaml"
kubectl apply -f "$tmpdir/10-keeper-chk.yaml"
kubectl -n clickhouse wait --for=condition=Ready pod -l app=clickhouse-keeper --timeout=300s || true
kubectl apply -f "$tmpdir/20-clickhouse-chi.yaml"
kubectl apply -f "$tmpdir/40-grafana-dashboard.yaml"

echo "==> [7/7] done. Watch rollout with: kubectl -n clickhouse get chi,chk,pods -w"
