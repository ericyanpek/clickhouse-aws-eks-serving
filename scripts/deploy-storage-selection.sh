#!/usr/bin/env bash
set -euo pipefail

# Restore a side-by-side 1x2 benchmark environment:
#   ch-local: i8g.4xlarge + local NVMe
#   ch-ebs:   r8g.4xlarge + tuned gp3
# Existing EBS, system, Keeper, and benchmark nodes are preserved.
cd "$(dirname "$0")/.."

if [ -z "${CLICKHOUSE_ADMIN_PASSWORD:-}" ]; then
  echo "ERROR: set CLICKHOUSE_ADMIN_PASSWORD." >&2
  exit 1
fi
if [ "${CONFIRM_CREATE_STORAGE_SELECTION_TEST:-}" != "yes" ]; then
  echo "ERROR: this adds two i8g.4xlarge benchmark nodes and restores ClickHouse workloads." >&2
  echo "Review the Terraform plan, then set CONFIRM_CREATE_STORAGE_SELECTION_TEST=yes." >&2
  exit 1
fi

LOCAL_ZONES=${LOCAL_NVME_COMPARISON_ZONES_TF:-'["us-east-1a"]'}
LOCAL_NODES_PER_ZONE=${LOCAL_NVME_COMPARISON_NODES_PER_ZONE:-2}
EBS_ZONES=${EBS_COMPARISON_ZONES_TF:-'["us-east-1a","us-east-1b"]'}
ADMIN_SHA=$(printf '%s' "$CLICKHOUSE_ADMIN_PASSWORD" | sha256sum | awk '{print $1}')
TF_ARGS=(
  -var=enable_local_nvme=false
  -var=enable_local_nvme_comparison=true
  -var="local_nvme_comparison_nodes_per_zone=$LOCAL_NODES_PER_ZONE"
  -var=enable_ebs_comparison=true
  -var="local_nvme_comparison_zones=$LOCAL_ZONES"
  -var="ebs_comparison_zones=$EBS_ZONES"
)
if [ "${AUTO_APPROVE:-false}" = "true" ]; then
  TF_ARGS+=(-input=false -auto-approve)
fi

if [ -n "${KUBE_API_OVERRIDE:-}" ]; then
  if [ -z "${KUBE_API_TLS_SERVER_NAME:-}" ]; then
    echo "ERROR: KUBE_API_TLS_SERVER_NAME is required with KUBE_API_OVERRIDE." >&2
    exit 1
  fi
  export TF_VAR_kube_api_endpoint_override=$KUBE_API_OVERRIDE
  export TF_VAR_kube_api_tls_server_name=$KUBE_API_TLS_SERVER_NAME
fi

configure_kubectl_override() {
  if [ -z "${KUBE_API_OVERRIDE:-}" ]; then
    return
  fi
  local kube_cluster
  kube_cluster=$(kubectl config view --minify -o jsonpath='{.contexts[0].context.cluster}')
  kubectl config set-cluster "$kube_cluster" \
    --server="$KUBE_API_OVERRIDE" \
    --tls-server-name="$KUBE_API_TLS_SERVER_NAME" >/dev/null
}

cd terraform
terraform init

echo "==> [1/7] adding the append-only local-NVMe benchmark node pool"
terraform apply "${TF_ARGS[@]}" -target=module.eks
eval "$(terraform output -raw configure_kubectl)"
configure_kubectl_override
cd ..

echo "==> [2/7] restoring the Altinity Operator without recreating existing CRDs"
if ! kubectl -n kube-system get deploy altinity-clickhouse-operator >/dev/null 2>&1; then
  helm upgrade --install altinity-clickhouse-operator altinity-clickhouse-operator \
    --repo https://altinity.github.io/clickhouse-operator \
    --version 0.27.1 \
    --namespace kube-system \
    --skip-crds \
    --wait \
    --timeout 10m
fi
kubectl -n kube-system rollout status deploy/altinity-clickhouse-operator --timeout=10m

cd terraform
if ! terraform state list | grep -qx 'module.operator.helm_release.altinity_clickhouse_operator'; then
  terraform import \
    "${TF_ARGS[@]}" \
    module.operator.helm_release.altinity_clickhouse_operator \
    kube-system/altinity-clickhouse-operator
fi
terraform apply "${TF_ARGS[@]}"
LOCAL_REPLICAS=$(terraform output -raw local_nvme_comparison_replica_count)
EBS_REPLICAS=$(terraform output -raw ebs_comparison_replica_count)
BUCKET=$(terraform output -raw backup_bucket)
ROLE_ARN=$(terraform output -raw backup_role_arn)
REGION=$(terraform output -raw region)
VOLUME_SIZE_GIB=$(terraform output -raw ebs_comparison_volume_size_gib)
eval "$(terraform output -raw configure_kubectl)"
configure_kubectl_override
cd ..

if [ "$LOCAL_REPLICAS" != "2" ] || [ "$EBS_REPLICAS" != "2" ]; then
  echo "ERROR: storage selection requires exactly two replicas per profile." >&2
  exit 1
fi

echo "==> [3/7] waiting for the two local-NVMe and two EBS nodes"
deadline=$((SECONDS + 2400))
while true; do
  local_nodes=$(kubectl get nodes -l workload=clickhouse-local-benchmark --no-headers 2>/dev/null | wc -l | tr -d ' ')
  ebs_nodes=$(kubectl get nodes -l workload=clickhouse-ebs --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [ "$local_nodes" -ge "$LOCAL_REPLICAS" ] && [ "$ebs_nodes" -ge "$EBS_REPLICAS" ]; then
    break
  fi
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "ERROR: benchmark nodes did not join within 40 minutes." >&2
    exit 1
  fi
  sleep 15
done

echo "==> [4/7] formatting local NVMe and publishing local PVs"
kubectl apply -f manifests/05-nvme-bootstrap.yaml
kubectl -n kube-system rollout status ds/nvme-bootstrap --timeout=15m
deadline=$((SECONDS + 900))
until [ "$(kubectl get pv -o jsonpath='{range .items[?(@.spec.storageClassName=="local-storage")]}{.metadata.name}{"\n"}{end}' | sed '/^$/d' | wc -l | tr -d ' ')" -ge "$LOCAL_REPLICAS" ]; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "ERROR: fewer than $LOCAL_REPLICAS local PVs were published." >&2
    exit 1
  fi
  sleep 10
done

echo "==> [5/7] rendering Keeper, backup, and both benchmark CHIs"
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
cp manifests/30-backup-cronjob.yaml "$tmpdir/backup.yaml"
cp manifests/70-clickhouse-chi-local-comparison.yaml "$tmpdir/chi-local.yaml"
cp manifests/50-clickhouse-chi-ebs-comparison.yaml "$tmpdir/chi-ebs.yaml"
sed -i.bak \
  -e "s|REPLACE_WITH_BACKUP_ROLE_ARN|$ROLE_ARN|g" \
  -e "s|REPLACE_WITH_BUCKET|$BUCKET|g" \
  -e "s|S3_REGION: \"us-east-1\"|S3_REGION: \"$REGION\"|g" \
  "$tmpdir/backup.yaml"
sed -i.bak \
  -e "s|REPLACE_WITH_ADMIN_SHA256|$ADMIN_SHA|g" \
  -e "s|REPLACE_WITH_LOCAL_REPLICA_COUNT|$LOCAL_REPLICAS|g" \
  "$tmpdir/chi-local.yaml"
sed -i.bak \
  -e "s|REPLACE_WITH_ADMIN_SHA256|$ADMIN_SHA|g" \
  -e "s|REPLACE_WITH_EBS_VOLUME_SIZE_GIB|${VOLUME_SIZE_GIB}Gi|g" \
  -e "s|REPLACE_WITH_EBS_REPLICA_COUNT|$EBS_REPLICAS|g" \
  "$tmpdir/chi-ebs.yaml"
awk 'BEGIN { doc=1 } /^---$/ { if (doc == 2) exit; doc++ } { print }' \
  "$tmpdir/backup.yaml" >"$tmpdir/backup-config-only.yaml"
if grep -q "REPLACE_WITH" \
  "$tmpdir/backup-config-only.yaml" \
  "$tmpdir/chi-local.yaml" \
  "$tmpdir/chi-ebs.yaml"; then
  echo "ERROR: rendered manifests still contain placeholders." >&2
  exit 1
fi

echo "==> [6/7] restoring Keeper and the two independent ClickHouse clusters"
kubectl apply -f manifests/00-namespace.yaml
kubectl apply -f "$tmpdir/backup-config-only.yaml"
kubectl apply -f manifests/10-keeper-chk.yaml
kubectl -n clickhouse wait \
  --for=condition=Ready pod \
  -l app=clickhouse-keeper \
  --timeout=20m
kubectl apply -f "$tmpdir/chi-local.yaml"
kubectl apply -f "$tmpdir/chi-ebs.yaml"
kubectl -n clickhouse wait \
  --for=condition=Ready pod \
  -l clickhouse.altinity.com/chi=ch-local \
  --timeout=30m
kubectl -n clickhouse wait \
  --for=condition=Ready pod \
  -l clickhouse.altinity.com/chi=ch-ebs \
  --timeout=30m

echo "==> [7/7] starting host disk metric collectors"
kubectl apply -f manifests/80-storage-metrics-collector.yaml
kubectl -n kube-system rollout status ds/storage-metrics-collector --timeout=10m

kubectl get nodes \
  -L workload,node.kubernetes.io/instance-type,topology.kubernetes.io/zone
kubectl -n clickhouse get chi,chk,pods,pvc -o wide
