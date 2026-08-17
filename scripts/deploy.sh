#!/usr/bin/env bash
set -euo pipefail
# Deploy ClickHouse on EKS. Run from repo root. Assumes AWS creds are configured.
# One EKS cluster hosts N independent ClickHouse clusters, one namespace each
# (ck-<key>). The set of clusters comes from Terraform, so adding a key to
# clickhouse_clusters is all it takes to get another cluster here.
cd "$(dirname "$0")/.."

# Validate secrets before Terraform can create any billable resources.
if [ -z "${CLICKHOUSE_ADMIN_PASSWORD:-}" ]; then
  echo "ERROR: set CLICKHOUSE_ADMIN_PASSWORD before deploy." >&2
  exit 1
fi
ADMIN_SHA=$(printf '%s' "$CLICKHOUSE_ADMIN_PASSWORD" | sha256sum | awk '{print $1}')

# Keep approval interactive for people. CI must explicitly opt in.
TF_APPLY_ARGS=()
if [ "${AUTO_APPROVE:-false}" = "true" ]; then
  TF_APPLY_ARGS=(-input=false -auto-approve)
fi

cd terraform
terraform init

# Two-phase apply. The kubernetes/helm providers are configured to talk to the EKS
# API endpoint, which does not exist until the cluster is built. Doing everything in
# ONE apply risks those providers trying to connect to a not-yet-ready cluster
# (operator/monitoring/storage helm releases fail or hang mid-apply). So:
#   Phase 1: build ONLY the AWS infra (VPC, EKS, node groups, S3, IRSA) — no in-cluster resources.
#   Phase 2: full apply — now the cluster is ACTIVE, so helm/kubernetes resources install cleanly.
# -target is a deliberate, documented use here (not a workaround for a broken graph).
echo "==> [1/6] terraform apply — phase 1: AWS infra only (EKS/VPC/nodegroups/S3/IRSA)"
terraform apply "${TF_APPLY_ARGS[@]}" \
  -target=module.eks \
  -target=aws_eks_node_group.clickhouse \
  -target=aws_eks_node_group.keeper \
  -target=aws_s3_bucket.backup \
  -target=aws_s3_bucket_versioning.backup \
  -target=aws_s3_bucket_server_side_encryption_configuration.backup \
  -target=aws_s3_bucket_public_access_block.backup \
  -target=aws_iam_role.backup \
  -target=aws_iam_role_policy.backup_s3

echo "==> [2/6] terraform apply — phase 2: in-cluster helm/k8s resources (operator/monitoring/storage)"
# Cluster is ACTIVE now; the kubernetes/helm providers can reach it. Full apply installs
# the operator, kube-prometheus-stack, and the per-cluster StorageClasses.
terraform apply "${TF_APPLY_ARGS[@]}"

BUCKET=$(terraform output -raw backup_bucket)
REGION=$(terraform output -raw region)
[ -n "$REGION" ] || {
  echo "ERROR: could not read region from terraform output" >&2
  exit 1
}
# The cluster set is data, not code: read the map outputs and iterate.
CLUSTERS=$(terraform output -json clickhouse_cluster_names |
  python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin)))')
CLUSTER_CFG=$(terraform output -json clickhouse_cluster_config)
BACKUP_ROLES=$(terraform output -json backup_role_arns)
eval "$(terraform output -raw configure_kubectl)"
cd ..

[ -n "$CLUSTERS" ] || {
  echo "ERROR: clickhouse_clusters is empty; nothing to deploy." >&2
  exit 1
}
echo "==> clusters to deploy: $CLUSTERS"

# All JSON access goes through python3 — hand-rolled JSON parsing in bash is how you
# end up shipping a cluster with the wrong storage class. Cluster/field names are
# passed as argv, never interpolated into the Python source.
cfg() {
  printf '%s' "$CLUSTER_CFG" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]][sys.argv[2]])' "$1" "$2"
}

# Booleans need normalising: Python prints JSON `true` as `True`, so comparing the raw
# output against one spelling is fragile. Let Python decide truthiness and emit a
# single canonical token.
cfg_bool() {
  printf '%s' "$CLUSTER_CFG" |
    python3 -c 'import json,sys; print("true" if json.load(sys.stdin)[sys.argv[1]][sys.argv[2]] else "false")' "$1" "$2"
}

backup_role_arn() {
  printf '%s' "$BACKUP_ROLES" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1"
}

# Emit "<placeholder>\t<value>" for every template placeholder of one cluster, in one
# pass, so rendering a template costs a single python3 call instead of ten.
render_pairs() {
  printf '%s' "$CLUSTER_CFG" | python3 -c '
import json, sys

cluster = sys.argv[1]
c = json.load(sys.stdin)[cluster]
pairs = [
    ("__CLUSTER__", cluster),
    ("__NAMESPACE__", c["namespace"]),
    ("__SHARDS__", c["shards"]),
    ("__REPLICAS__", c["replicas"]),
    ("__STORAGE_CLASS__", c["storage_class"]),
    ("__DATA_VOLUME_SIZE__", c["data_volume_size_gib"]),
    ("__CLICKHOUSE_IMAGE__", c["clickhouse_image"]),
    ("__KEEPER_IMAGE__", c["keeper_image"]),
    ("__CPU_REQUEST__", c["cpu_request"]),
    ("__MEMORY_REQUEST__", c["memory_request"]),
]
for k, v in pairs:
    print("%s\t%s" % (k, v))
' "$1"
}

render() {
  local tmpl=$1 out=$2 cluster=$3
  local sed_args=() placeholder value
  while IFS=$'\t' read -r placeholder value; do
    [ -n "$placeholder" ] || continue
    sed_args+=(-e "s|$placeholder|$value|g")
  done < <(render_pairs "$cluster")
  [ ${#sed_args[@]} -gt 0 ] || {
    echo "ERROR[$cluster]: could not read render values from terraform output" >&2
    return 1
  }
  sed "${sed_args[@]}" "$tmpl" >"$out"
}

# The CHI carries two backup-only pieces: a serviceAccountName and the sidecar
# container. Both must disappear when a cluster has enable_backup = false, because
# the ServiceAccount and ConfigMap they reference are created by the backup manifest
# alone -- a pod naming a missing ServiceAccount is rejected by admission, so the
# StatefulSet would never produce a single pod.
#
# The sidecar is substituted from a fragment file rather than inline: it is 32 lines
# of indented YAML, and sed's `s` command cannot introduce newlines portably.
render_chi() {
  local out=$1 cluster=$2 want_backup=$3
  local frag=manifests/templates/20-clickhouse-chi-backup-sidecar.yaml.frag

  if [ "$want_backup" = "true" ]; then
    [ -f "$frag" ] || {
      echo "ERROR[$cluster]: backup sidecar fragment $frag is missing." >&2
      return 1
    }
    # Splice the fragment in BEFORE substituting, so its own placeholders (the
    # sidecar's S3_PATH is __CLUSTER__) get rendered along with the rest. Appending
    # after substitution would ship a literal __CLUSTER__ as the S3 path, which the
    # cluster-scoped backup IAM role then denies on every upload.
    #
    # `r` appends the file after the marker line and `d` removes the marker, so the
    # fragment keeps exactly the indentation it was written with.
    sed -e "/__BACKUP_SIDECAR__/r $frag" -e "/__BACKUP_SIDECAR__/d" \
      -e "s|__SERVICE_ACCOUNT_LINE__|serviceAccountName: clickhouse-backup|" \
      manifests/templates/20-clickhouse-chi.yaml.tmpl >"$out.pre"
  else
    # Drop the sidecar marker entirely, and the serviceAccountName line with it.
    sed -e "/__BACKUP_SIDECAR__/d" -e "/__SERVICE_ACCOUNT_LINE__/d" \
      manifests/templates/20-clickhouse-chi.yaml.tmpl >"$out.pre"
  fi

  render "$out.pre" "$out" "$cluster" || return 1
  rm -f "$out.pre"
}

# Count Ready nodes carrying a label set. Always prints a number, so a transient
# kubectl failure cannot make an arithmetic comparison explode.
ready_nodes() {
  kubectl get nodes -l "$1" --no-headers 2>/dev/null |
    awk '$2 == "Ready" { n++ } END { print n + 0 }'
}

# Preflight checks 1-5. Each one maps to a failure actually hit while building this:
# without them the symptom is a Pending pod or a silently broken sidecar, and the
# cause is several layers away from the symptom.
preflight() {
  local cluster=$1
  local sc profile ns shards replicas want_nodes have_nodes binding
  sc=$(cfg "$cluster" storage_class)
  profile=$(cfg "$cluster" storage_profile)
  ns=$(cfg "$cluster" namespace)
  shards=$(cfg "$cluster" shards)
  replicas=$(cfg "$cluster" replicas)

  case "$profile" in
    ebs | local-nvme) ;;
    *)
      echo "ERROR[$cluster]: unexpected storage_profile '$profile' (want ebs or local-nvme)." >&2
      return 1
      ;;
  esac

  # 1. StorageClass exists. Missing -> every PVC stays Pending forever with no
  #    obvious cause; nothing in the CHI status points at the class.
  kubectl get storageclass "$sc" >/dev/null 2>&1 || {
    echo "ERROR[$cluster]: StorageClass '$sc' not found; Terraform should have created it for storage_profile=$profile." >&2
    return 1
  }

  # 2. WaitForFirstConsumer. A gp3 volume is AZ-scoped, so binding it before the pod
  #    is scheduled can place it in an AZ the pod will never run in.
  binding=$(kubectl get storageclass "$sc" -o jsonpath='{.volumeBindingMode}' 2>/dev/null || true)
  [ "$binding" = "WaitForFirstConsumer" ] || {
    echo "ERROR[$cluster]: StorageClass '$sc' has volumeBindingMode=${binding:-<unset>}; WaitForFirstConsumer is required so AZ-scoped volumes bind where the pod runs." >&2
    return 1
  }

  # 3. Enough data nodes. The CHI provisions shards x replicas pods and each needs its
  #    own node (pod anti-affinity), so the node budget is the product, not replicas.
  want_nodes=$((shards * replicas))
  have_nodes=$(ready_nodes "workload=clickhouse,ck-cluster=$cluster")
  [ "$have_nodes" -ge "$want_nodes" ] || {
    echo "ERROR[$cluster]: only $have_nodes Ready node(s) labelled workload=clickhouse,ck-cluster=$cluster, need $want_nodes (shards=$shards x replicas=$replicas)." >&2
    return 1
  }

  # 4. Keeper nodes. Fewer than 3 means no real Raft quorum.
  have_nodes=$(ready_nodes "workload=keeper,ck-cluster=$cluster")
  [ "$have_nodes" -ge 3 ] || {
    echo "ERROR[$cluster]: only $have_nodes Ready node(s) labelled workload=keeper,ck-cluster=$cluster, need 3." >&2
    return 1
  }

  # 5. The storage medium's node-level component is installed.
  if [ "$profile" = "local-nvme" ]; then
    kubectl -n kube-system get daemonset nvme-bootstrap >/dev/null 2>&1 || {
      echo "ERROR[$cluster]: nvme-bootstrap DaemonSet missing from kube-system; instance-store NVMe would stay unmounted and PVCs Pending." >&2
      return 1
    }
  else
    kubectl -n kube-system get daemonset ebs-csi-node >/dev/null 2>&1 || {
      echo "ERROR[$cluster]: ebs-csi-node DaemonSet missing from kube-system; the EBS CSI driver addon is required for storage_profile=ebs." >&2
      return 1
    }
  fi

  echo "    preflight[$cluster] OK (profile=$profile storage=$sc ns=$ns topology=${shards}x${replicas})"
}

echo "==> [3/6] waiting for operator to be ready"
# Blueprint installs the operator as helm release 'altinity-clickhouse-operator' in kube-system.
kubectl -n kube-system rollout status deploy/altinity-clickhouse-operator --timeout=180s ||
  echo "WARNING: operator rollout did not complete in time — CHI apply may fail" >&2

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

echo "==> [4/6] preparing cluster-wide storage prerequisites"
# The NVMe bootstrap DaemonSet is cluster-wide (it targets storage=local-nvme nodes,
# whichever cluster they belong to), so it is applied once rather than per cluster.
needs_nvme=false
for cluster in $CLUSTERS; do
  if [ "$(cfg "$cluster" storage_profile)" = "local-nvme" ]; then
    needs_nvme=true
  fi
done
if [ "$needs_nvme" = "true" ]; then
  # AL2023 does not auto-mount instance store; this DaemonSet mounts it under
  # /mnt/disks so the local-static-provisioner can publish local PVs.
  kubectl apply -f manifests/05-nvme-bootstrap.yaml
  kubectl -n kube-system rollout status ds/nvme-bootstrap --timeout=180s ||
    echo "WARNING: nvme-bootstrap DaemonSet not ready — local-nvme PVCs may stay Pending" >&2
else
  echo "    no local-nvme cluster configured; skipping nvme-bootstrap"
fi

echo "==> [5/6] deploying clusters"
for cluster in $CLUSTERS; do
  ns=$(cfg "$cluster" namespace)
  shards=$(cfg "$cluster" shards)
  replicas=$(cfg "$cluster" replicas)
  echo "==> cluster '$cluster' -> namespace '$ns' (${shards}x${replicas})"

  preflight "$cluster"

  # One directory per cluster so a rendered file can never be mistaken for another
  # cluster's, and so the placeholder scan below has an exact file list.
  dir="$tmpdir/$cluster"
  mkdir -p "$dir"

  backup_enabled=$(cfg_bool "$cluster" enable_backup)

  render manifests/templates/10-keeper-chk.yaml.tmpl "$dir/chk.yaml" "$cluster"
  render_chi "$dir/chi.yaml" "$cluster" "$backup_enabled"
  rendered=("$dir/chk.yaml" "$dir/chi.yaml")

  # Second substitution pass, over the RENDERED files: secrets and account-specific
  # values never pass through the templates on disk.
  sed -i.bak "s|REPLACE_WITH_ADMIN_SHA256|$ADMIN_SHA|g" "$dir/chi.yaml"

  if [ "$backup_enabled" = "true" ]; then
    role_arn=$(backup_role_arn "$cluster")
    [ -n "$role_arn" ] || {
      echo "ERROR[$cluster]: enable_backup is true but no backup role ARN was returned by Terraform." >&2
      exit 1
    }
    render manifests/templates/30-backup-cronjob.yaml.tmpl "$dir/backup.yaml" "$cluster"
    sed -i.bak \
      -e "s|REPLACE_WITH_BACKUP_ROLE_ARN|$role_arn|g" \
      -e "s|REPLACE_WITH_BUCKET|$BUCKET|g" \
      -e "s|S3_REGION: \"us-east-1\"|S3_REGION: \"$REGION\"|g" \
      "$dir/backup.yaml"
    rendered+=("$dir/backup.yaml")
  else
    # render_chi already dropped the serviceAccountName line and the sidecar, so the
    # pod spec no longer references anything the backup manifest would have created.
    echo "    backup disabled for '$cluster'; ServiceAccount, ConfigMap, CronJob and sidecar all omitted"
  fi
  rm -f "$dir"/*.bak

  # 6. No placeholder survived either substitution pass. A leftover REPLACE_WITH
  #    breaks auth or IRSA silently; a leftover __UPPER__ ships a manifest that
  #    references a StorageClass or image that does not exist.
  if grep -nE 'REPLACE_WITH|__[A-Z][A-Z0-9_]*__' "${rendered[@]}"; then
    echo "ERROR[$cluster]: unsubstituted placeholder remains in the rendered manifests (shown above)." >&2
    exit 1
  fi

  # Apply order matters: the backup ServiceAccount must exist before the CHI, whose
  # podTemplate sets serviceAccountName: clickhouse-backup.
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
  if [ "$backup_enabled" = "true" ]; then
    kubectl apply -f "$dir/backup.yaml"
  fi
  kubectl apply -f "$dir/chk.yaml"

  # 7. Keeper quorum before the CHI. Applying the CHI against a Keeper that has not
  #    formed a quorum makes the ClickHouse pods crash-loop on coordination errors.
  echo "    waiting for Keeper quorum in $ns"
  kubectl -n "$ns" wait --for=condition=Ready pod -l app=clickhouse-keeper --timeout=600s || {
    echo "ERROR[$cluster]: Keeper did not reach Ready; refusing to apply the CHI." >&2
    exit 1
  }

  kubectl apply -f "$dir/chi.yaml"
  echo "    waiting for ClickHouse pods in $ns"
  kubectl -n "$ns" wait --for=condition=Ready pod -l "clickhouse.altinity.com/chi=$cluster" --timeout=900s ||
    echo "WARNING[$cluster]: pods not all Ready within timeout; check kubectl -n $ns get pods" >&2

  CLICKHOUSE_NAMESPACE="$ns" \
    CLICKHOUSE_CHI="$cluster" \
    EXPECTED_SHARDS="$shards" \
    EXPECTED_REPLICAS="$replicas" \
    ./scripts/smoke-test.sh || {
    echo "ERROR[$cluster]: smoke test failed." >&2
    exit 1
  }

  echo "==> cluster '$cluster' ready"
done

echo "==> [6/6] applying shared monitoring dashboard"
# Cluster-independent: one ConfigMap in the monitoring namespace, not per ClickHouse cluster.
kubectl apply -f manifests/40-grafana-dashboard.yaml

echo "==> all clusters deployed: $CLUSTERS"
for cluster in $CLUSTERS; do
  echo "    kubectl -n $(cfg "$cluster" namespace) get chi,chk,pods"
done
