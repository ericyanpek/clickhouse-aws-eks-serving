#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if [ "${CONFIRM_DELETE_EBS_COMPARISON:-}" != "yes" ]; then
  echo "ERROR: this deletes ch-ebs and its EBS volumes." >&2
  echo "Re-run with CONFIRM_DELETE_EBS_COMPARISON=yes." >&2
  exit 1
fi

TF_APPLY_ARGS=()
if [ "${AUTO_APPROVE:-false}" = "true" ]; then
  TF_APPLY_ARGS=(-input=false -auto-approve)
fi

cd terraform
terraform init
CONFIGURE_KUBECTL=$(terraform output -raw configure_kubectl 2>/dev/null || true)
if [ -z "$CONFIGURE_KUBECTL" ]; then
  echo "ERROR: no deployed Terraform state was found; refusing to use the current kubectl context." >&2
  exit 1
fi
eval "$CONFIGURE_KUBECTL"
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

echo "==> deleting only the optional ch-ebs workload"
kubectl -n clickhouse delete chi ch-ebs --ignore-not-found --wait=true
kubectl -n clickhouse delete pdb ch-ebs-pdb --ignore-not-found
kubectl -n clickhouse delete pod storage-comparison-client --ignore-not-found
# Stateful workload deletion can retain claims depending on operator policy.
# Delete only claims labelled for ch-ebs so their Delete-reclaim EBS PVs are released.
kubectl -n clickhouse delete pvc \
  -l clickhouse.altinity.com/chi=ch-ebs \
  --ignore-not-found \
  --wait=true

echo "==> removing only the optional R8g node pools and comparison StorageClass"
cd terraform
terraform apply "${TF_APPLY_ARGS[@]}" -var=enable_ebs_comparison=false

echo "==> EBS comparison add-on removed; baseline ch cluster remains."
echo "Set enable_ebs_comparison=false in terraform/terraform.tfvars before future applies."
