#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if [ "${CONFIRM_DELETE_EBS_ONLY_TEST:-}" != "yes" ]; then
  echo "ERROR: this destroys the entire EBS-only test environment and its data volumes." >&2
  echo "Re-run with CONFIRM_DELETE_EBS_ONLY_TEST=yes." >&2
  exit 1
fi

TF_DESTROY_ARGS=(-var=enable_local_nvme=false -var=enable_ebs_comparison=true)
if [ "${AUTO_APPROVE:-false}" = "true" ]; then
  TF_DESTROY_ARGS+=(-input=false -auto-approve)
fi

cd terraform
terraform init
CONFIGURE_KUBECTL=$(terraform output -raw configure_kubectl 2>/dev/null || true)
if [ -z "$CONFIGURE_KUBECTL" ]; then
  echo "ERROR: no deployed Terraform state was found." >&2
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

echo "==> deleting EBS-only ClickHouse, Keeper, and PVCs"
kubectl -n clickhouse delete chi ch-ebs --ignore-not-found --wait=true
kubectl -n clickhouse delete pod storage-comparison-client --ignore-not-found
kubectl -n clickhouse delete chk keeper --ignore-not-found --wait=true
kubectl -n clickhouse delete pvc --all --ignore-not-found --wait=true
kubectl delete namespace clickhouse --ignore-not-found --wait=true

echo "==> removing in-cluster Terraform resources while the EKS API is available"
cd terraform
terraform destroy "${TF_DESTROY_ARGS[@]}" \
  -target=module.operator \
  -target=helm_release.kube_prometheus_stack \
  -target=helm_release.local_static_provisioner \
  -target=kubernetes_namespace.monitoring \
  -target=kubernetes_storage_class.local \
  -target=kubernetes_storage_class.clickhouse_ebs_comparison

echo "==> destroying the remaining EBS-only AWS infrastructure"
terraform destroy "${TF_DESTROY_ARGS[@]}"
echo "==> EBS-only test environment removed"
