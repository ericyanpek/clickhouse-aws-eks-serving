#!/usr/bin/env bash
set -euo pipefail

# Build only the EBS profile needed to compare with the historical 1x2 NVMe results.
# No i8g/local-NVMe node pool or baseline CHI is created.
cd "$(dirname "$0")/.."

if [ -z "${CLICKHOUSE_ADMIN_PASSWORD:-}" ]; then
  echo "ERROR: set CLICKHOUSE_ADMIN_PASSWORD before deploying the EBS-only test." >&2
  exit 1
fi
if [ "${CONFIRM_CREATE_EBS_ONLY_TEST:-}" != "yes" ]; then
  echo "ERROR: this creates a new EKS environment, 2 R8g nodes, and 2 tuned gp3 volumes." >&2
  echo "Re-run with CONFIRM_CREATE_EBS_ONLY_TEST=yes after reviewing the cost." >&2
  exit 1
fi

ADMIN_SHA=$(printf '%s' "$CLICKHOUSE_ADMIN_PASSWORD" | sha256sum | awk '{print $1}')
TF_APPLY_ARGS=(-var=enable_local_nvme=false -var=enable_ebs_comparison=true)
if [ "${AUTO_APPROVE:-false}" = "true" ]; then
  TF_APPLY_ARGS+=(-input=false -auto-approve)
fi

cd terraform
terraform init

echo "==> [1/6] creating EKS and EBS-only node pools"
terraform apply "${TF_APPLY_ARGS[@]}" \
  -target=module.eks \
  -target=aws_s3_bucket.backup \
  -target=aws_s3_bucket_versioning.backup \
  -target=aws_s3_bucket_server_side_encryption_configuration.backup \
  -target=aws_s3_bucket_public_access_block.backup \
  -target=aws_iam_role.backup \
  -target=aws_iam_role_policy.backup_s3

echo "==> [2/6] installing operator, monitoring, and StorageClasses"
terraform apply "${TF_APPLY_ARGS[@]}"

BUCKET=$(terraform output -raw backup_bucket)
ROLE_ARN=$(terraform output -raw backup_role_arn)
REGION=$(terraform output -raw region)
VOLUME_SIZE_GIB=$(terraform output -raw ebs_comparison_volume_size_gib)
REPLICA_COUNT=$(terraform output -raw ebs_comparison_replica_count)
if [ "$REPLICA_COUNT" != "2" ]; then
  echo "ERROR: EBS-only historical comparison requires exactly 2 ebs_comparison_zones." >&2
  exit 1
fi
eval "$(terraform output -raw configure_kubectl)"
cd ..

if [ -n "${KUBE_API_OVERRIDE:-}" ]; then
  if [ -z "${KUBE_API_TLS_SERVER_NAME:-}" ]; then
    echo "ERROR: KUBE_API_TLS_SERVER_NAME is required with KUBE_API_OVERRIDE." >&2
    exit 1
  fi
  KUBE_CLUSTER=$(kubectl config view --minify -o jsonpath='{.contexts[0].context.cluster}')
  kubectl config set-cluster "$KUBE_CLUSTER" \
    --server="$KUBE_API_OVERRIDE" \
    --tls-server-name="$KUBE_API_TLS_SERVER_NAME" >/dev/null
fi

echo "==> [3/6] waiting for operator and $REPLICA_COUNT EBS nodes"
kubectl -n kube-system rollout status deploy/altinity-clickhouse-operator --timeout=10m
deadline=$((SECONDS + 1800))
until [ "$(kubectl get nodes -l workload=clickhouse-ebs --no-headers 2>/dev/null | wc -l | tr -d ' ')" -ge "$REPLICA_COUNT" ]; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "ERROR: fewer than $REPLICA_COUNT EBS nodes joined within 30 minutes." >&2
    exit 1
  fi
  sleep 15
done

echo "==> [4/6] rendering EBS-only manifests"
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
cp manifests/30-backup-cronjob.yaml "$tmpdir/backup.yaml"
cp manifests/50-clickhouse-chi-ebs-comparison.yaml "$tmpdir/chi-ebs.yaml"
sed -i.bak \
  -e "s|REPLACE_WITH_BACKUP_ROLE_ARN|$ROLE_ARN|g" \
  -e "s|REPLACE_WITH_BUCKET|$BUCKET|g" \
  -e "s|S3_REGION: \"us-east-1\"|S3_REGION: \"$REGION\"|g" \
  "$tmpdir/backup.yaml"
sed -i.bak \
  -e "s|REPLACE_WITH_ADMIN_SHA256|$ADMIN_SHA|g" \
  -e "s|REPLACE_WITH_EBS_VOLUME_SIZE_GIB|${VOLUME_SIZE_GIB}Gi|g" \
  -e "s|REPLACE_WITH_EBS_REPLICA_COUNT|${REPLICA_COUNT}|g" \
  "$tmpdir/chi-ebs.yaml"
awk 'BEGIN { doc=1 } /^---$/ { if (doc == 2) exit; doc++ } { print }' \
  "$tmpdir/backup.yaml" >"$tmpdir/backup-config-only.yaml"
if grep -rq "REPLACE_WITH" "$tmpdir/backup-config-only.yaml" "$tmpdir/chi-ebs.yaml"; then
  echo "ERROR: an unsubstituted placeholder remains in the rendered manifests." >&2
  exit 1
fi

echo "==> [5/6] applying Keeper and the 1x2 EBS CHI"
kubectl apply -f manifests/00-namespace.yaml
kubectl apply -f "$tmpdir/backup-config-only.yaml"
kubectl apply -f manifests/10-keeper-chk.yaml
kubectl -n clickhouse wait \
  --for=condition=Ready pod \
  -l app=clickhouse-keeper \
  --timeout=15m
kubectl apply -f "$tmpdir/chi-ebs.yaml"
kubectl apply -f manifests/40-grafana-dashboard.yaml
kubectl -n clickhouse wait \
  --for=condition=Ready pod \
  -l clickhouse.altinity.com/chi=ch-ebs \
  --timeout=30m

echo "==> [6/6] EBS-only test environment is ready"
kubectl -n clickhouse get chi,chk,pods,pvc -o wide
echo "Run: COMPARE_LOCAL=false CLICKHOUSE_ADMIN_PASSWORD='...' ./scripts/run-storage-comparison.sh"
