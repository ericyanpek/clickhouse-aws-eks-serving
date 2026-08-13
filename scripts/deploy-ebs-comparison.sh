#!/usr/bin/env bash
set -euo pipefail

# Add the optional ch-ebs comparison cluster to an already deployed local-NVMe stack.
# Existing ClickHouse nodes, PVCs, CHI, and services are not modified.
cd "$(dirname "$0")/.."

if [ -z "${CLICKHOUSE_ADMIN_PASSWORD:-}" ]; then
  echo "ERROR: set CLICKHOUSE_ADMIN_PASSWORD before deploying the comparison cluster." >&2
  exit 1
fi
if [ "${CONFIRM_CREATE_EBS_COMPARISON:-}" != "yes" ]; then
  echo "ERROR: this add-on creates 3 R8g nodes and 3 high-performance gp3 volumes." >&2
  echo "Review the Terraform plan and re-run with CONFIRM_CREATE_EBS_COMPARISON=yes." >&2
  exit 1
fi
ADMIN_SHA=$(printf '%s' "$CLICKHOUSE_ADMIN_PASSWORD" | sha256sum | awk '{print $1}')

TF_APPLY_ARGS=()
if [ "${AUTO_APPROVE:-false}" = "true" ]; then
  TF_APPLY_ARGS=(-input=false -auto-approve)
fi

cd terraform
terraform init

CONFIGURE_KUBECTL=$(terraform output -raw configure_kubectl 2>/dev/null || true)
if [ -z "$CONFIGURE_KUBECTL" ]; then
  echo "ERROR: no deployed baseline Terraform state was found; run scripts/deploy.sh first." >&2
  exit 1
fi
eval "$CONFIGURE_KUBECTL"
cd ..

for resource in \
  "chi/ch" \
  "chk/keeper" \
  "serviceaccount/clickhouse-backup" \
  "configmap/clickhouse-backup-config"; do
  if ! kubectl -n clickhouse get "$resource" >/dev/null 2>&1; then
    echo "ERROR: baseline resource clickhouse/$resource is missing; deploy the local-NVMe stack first." >&2
    exit 1
  fi
done

echo "==> adding the optional R8g + gp3 comparison node pool and StorageClass"
cd terraform
terraform apply "${TF_APPLY_ARGS[@]}" -var=enable_ebs_comparison=true
VOLUME_SIZE_GIB=$(terraform output -raw ebs_comparison_volume_size_gib)
REPLICA_COUNT=$(terraform output -raw ebs_comparison_replica_count)
eval "$(terraform output -raw configure_kubectl)"
cd ..

echo "==> waiting for $REPLICA_COUNT EBS comparison nodes"
deadline=$((SECONDS + 1800))
until [ "$(kubectl get nodes -l workload=clickhouse-ebs --no-headers 2>/dev/null | wc -l | tr -d ' ')" -ge "$REPLICA_COUNT" ]; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "ERROR: fewer than $REPLICA_COUNT workload=clickhouse-ebs nodes joined within 30 minutes." >&2
    exit 1
  fi
  sleep 15
done

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
cp manifests/50-clickhouse-chi-ebs-comparison.yaml "$tmpdir/chi-ebs.yaml"
sed -i.bak \
  -e "s|REPLACE_WITH_ADMIN_SHA256|$ADMIN_SHA|g" \
  -e "s|REPLACE_WITH_EBS_VOLUME_SIZE_GIB|${VOLUME_SIZE_GIB}Gi|g" \
  -e "s|REPLACE_WITH_EBS_REPLICA_COUNT|${REPLICA_COUNT}|g" \
  "$tmpdir/chi-ebs.yaml"

if grep -q "REPLACE_WITH" "$tmpdir/chi-ebs.yaml"; then
  echo "ERROR: an unsubstituted placeholder remains in the rendered EBS CHI." >&2
  exit 1
fi

echo "==> applying the independent ch-ebs CHI"
kubectl apply -f "$tmpdir/chi-ebs.yaml"
kubectl -n clickhouse wait \
  --for=condition=Ready pod \
  -l clickhouse.altinity.com/chi=ch-ebs \
  --timeout=30m

echo "==> EBS comparison cluster is ready"
kubectl -n clickhouse get chi ch ch-ebs
kubectl -n clickhouse get pods,pvc -l clickhouse.altinity.com/chi=ch-ebs -o wide
echo "IMPORTANT: keep enable_ebs_comparison=true in terraform/terraform.tfvars"
echo "while ch-ebs exists; a later Terraform apply with false removes its nodes and StorageClass."
echo "Run: CLICKHOUSE_ADMIN_PASSWORD='...' ./scripts/run-storage-comparison.sh"
