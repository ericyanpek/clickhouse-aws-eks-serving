#!/usr/bin/env bash
set -euo pipefail
# Ordered teardown.
#
#   ./scripts/teardown.sh                 # everything: all clusters + all AWS infra
#   ./scripts/teardown.sh --cluster ebs   # one ClickHouse cluster only, EKS stays up
#
# Three real destroy failures shaped this script:
#   1. A dropped SSM tunnel left a helm_release destroy stalling for 5 minutes and then
#      failing, with ZERO resources destroyed. Hence: every resource that needs the
#      Kubernetes API is removed from state BEFORE `terraform destroy` runs.
#   2. A local DNS failure interrupted a run whose EKS delete requests had already
#      taken effect. Hence: the whole path is re-entrant and destroy retries once.
#   3. The original script deleted by manifest FILENAME, so it looked for a CHI named
#      'ch' and silently skipped the ch-ebs/ch-local that actually existed -- deleting
#      PVCs while their pods still held them. Hence: delete what exists (`delete --all`),
#      never what a file happens to name.
cd "$(dirname "$0")/.."

ONLY_CLUSTER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --cluster)
      ONLY_CLUSTER=${2:?--cluster requires a name}
      shift 2
      ;;
    -h | --help)
      echo "usage: $0 [--cluster <key>]"
      exit 0
      ;;
    *)
      echo "usage: $0 [--cluster <key>]" >&2
      exit 64
      ;;
  esac
done

AWS_CLI_REGION=${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}

# CRITICAL: the per-cluster gp3 StorageClasses use reclaim_policy = Retain, so deleting
# a PVC leaves the PV and the underlying EBS volume in place, still billed. Nothing else
# reclaims them: the volumes are created by the CSI driver, not Terraform, so they are
# absent from state and survive `terraform destroy` and even the EKS cluster itself. At
# the default 3 x 3400 GiB that is over $1,000/month for volumes attached to nothing.
#
# The volume IDs must be read BEFORE the namespace and PV objects are deleted --
# afterwards the only handle left is the tag sweep in delete_volumes, kept there as a
# fallback rather than the primary path.
collect_volume_ids() {
  kubectl get pv -o json 2>/dev/null | python3 -c '
import json, sys

ns = sys.argv[1]
try:
    pvs = json.load(sys.stdin).get("items", [])
except ValueError:
    pvs = []
for pv in pvs:
    spec = pv.get("spec", {})
    ref = spec.get("claimRef") or {}
    if ref.get("namespace") != ns:
        continue
    handle = (spec.get("csi") or {}).get("volumeHandle")
    if handle and handle.startswith("vol-"):
        print(handle)
' "$1"
}

delete_volumes() {
  local ns=$1 ids=$2 vol attempt
  for vol in $ids; do
    echo "    deleting EBS volume $vol (Retain left it behind)"
    for attempt in 1 2 3 4 5 6; do
      if aws ec2 delete-volume --volume-id "$vol" --region "$AWS_CLI_REGION" >/dev/null 2>&1; then
        break
      fi
      # A volume that is still detaching rejects deletion; give it a moment rather
      # than leaking it. Six tries at 10s covers the observed detach window.
      if [ "$attempt" -eq 6 ]; then
        echo "WARNING: could not delete volume $vol after 6 attempts; delete it manually." >&2
      else
        sleep 10
      fi
    done
  done

  # Belt and braces: catch volumes whose PV object was already gone (an interrupted
  # earlier run), found by the tag the CSI driver sets at provision time.
  local swept
  swept=$(volumes_for_namespace "$ns" available)
  if [ -n "$swept" ]; then
    echo "    tag sweep found extra available volume(s) for $ns"
    for vol in $swept; do
      echo "    deleting swept EBS volume $vol"
      aws ec2 delete-volume --volume-id "$vol" --region "$AWS_CLI_REGION" >/dev/null 2>&1 ||
        echo "WARNING: could not delete swept volume $vol; delete it manually." >&2
    done
  fi
}

# Newline-separated volume IDs tagged for a namespace. Second arg optionally filters
# by state; empty means any state.
volumes_for_namespace() {
  local ns=$1 state=${2:-} filters
  filters=("Name=tag:kubernetes.io/created-for/pvc/namespace,Values=$ns")
  [ -n "$state" ] && filters+=("Name=status,Values=$state")
  aws ec2 describe-volumes --region "$AWS_CLI_REGION" \
    --filters "${filters[@]}" \
    --query 'Volumes[].VolumeId' --output text 2>/dev/null |
    tr '\t' '\n' | sed '/^$/d;/^None$/d'
}

verify_volumes_released() {
  local ns=$1 left
  left=$(volumes_for_namespace "$ns")
  if [ -n "$left" ]; then
    echo "WARNING: EBS volume(s) still tagged for namespace $ns:" >&2
    printf '%s\n' "$left" | sed 's/^/         /' >&2
    echo "         reclaim_policy is Retain, so nothing will reclaim them once the" >&2
    echo "         control plane is gone. Delete them manually:" >&2
    echo "         aws ec2 delete-volume --region $AWS_CLI_REGION --volume-id <id>" >&2
    return 1
  fi
  echo "    all volumes for $ns released"
}

# Delete in dependency order: CHI, then Keeper, then any leftover PVCs, then the
# namespace. Pods must actually terminate before the PVCs go, because a volume only
# detaches after its pod is gone -- and a still-attached volume cannot be deleted.
delete_cluster_in_k8s() {
  local ns=$1 vol_ids
  if ! kubectl get namespace "$ns" >/dev/null 2>&1; then
    echo "    namespace $ns absent, skipping in-cluster teardown"
    return 0
  fi

  # Read the volume handles while the PV objects still exist.
  vol_ids=$(collect_volume_ids "$ns")

  echo "    deleting ClickHouse installations in $ns"
  kubectl -n "$ns" delete chi --all --ignore-not-found --timeout=600s || true
  echo "    waiting for ClickHouse pods in $ns to terminate (volumes detach only then)"
  kubectl -n "$ns" wait --for=delete pod -l clickhouse.altinity.com/app=chop --timeout=600s 2>/dev/null || true

  echo "    deleting Keeper installations in $ns"
  kubectl -n "$ns" delete chk --all --ignore-not-found --timeout=300s || true
  kubectl -n "$ns" wait --for=delete pod -l app=clickhouse-keeper --timeout=300s 2>/dev/null || true

  echo "    deleting remaining PVCs in $ns"
  kubectl -n "$ns" delete pvc --all --ignore-not-found --timeout=300s || true

  echo "    deleting namespace $ns"
  kubectl delete namespace "$ns" --ignore-not-found --timeout=300s || true

  # Retain means the volumes are still billed until explicitly deleted.
  delete_volumes "$ns" "$vol_ids"
}

if [ -n "$ONLY_CLUSTER" ]; then
  ns="ck-$ONLY_CLUSTER"
  echo "==> tearing down only cluster '$ONLY_CLUSTER' (namespace $ns); EKS stays up"
  delete_cluster_in_k8s "$ns"
  verify_volumes_released "$ns" || echo "WARNING: continuing despite unreleased volumes in $ns" >&2

  echo "==> destroying Terraform resources for '$ONLY_CLUSTER' only"
  # Every per-cluster resource is for_each-keyed by the cluster key, so targeting
  # addresses whose index starts with ["<key> touches nothing else. Discover them from
  # state rather than listing addresses that may not exist (a missing -target fails).
  targets=()
  while IFS= read -r addr; do
    [ -n "$addr" ] && targets+=(-target="$addr")
  done < <(terraform -chdir=terraform state list 2>/dev/null |
    grep -E "^(aws_eks_node_group\.(clickhouse|keeper)|kubernetes_storage_class\.clickhouse_gp3|aws_iam_role\.backup|aws_iam_role_policy\.backup_s3)\[\"$ONLY_CLUSTER" || true)

  if [ ${#targets[@]} -eq 0 ]; then
    echo "    no Terraform resources found for '$ONLY_CLUSTER'"
  else
    terraform -chdir=terraform destroy -auto-approve "${targets[@]}"
  fi
  echo "==> cluster '$ONLY_CLUSTER' torn down."
  echo "    NEXT: remove the '$ONLY_CLUSTER' key from clickhouse_clusters in terraform.tfvars"
  echo "    so config and state agree; otherwise the next apply recreates it."
  exit 0
fi

echo "==> full teardown: all clusters + all AWS infra"
# Discover namespaces from the cluster, not from an assumed list: an interrupted run or
# a key removed from tfvars can leave a namespace that no config mentions.
namespaces=$(kubectl get namespace -o name 2>/dev/null | sed 's|^namespace/||' | grep '^ck-' || true)
if [ -z "$namespaces" ]; then
  echo "    no ck-* namespaces found (cluster already gone or unreachable); continuing"
else
  for ns in $namespaces; do
    echo "==> in-cluster teardown of $ns"
    delete_cluster_in_k8s "$ns"
    verify_volumes_released "$ns" || echo "WARNING: continuing despite unreleased volumes in $ns" >&2
  done
fi

cd terraform

# Capture the bucket name before it leaves state, so the operator has an exact name to
# retain or delete later. Tolerate a missing output: the full path must stay re-entrant.
BACKUP_BUCKET=$(terraform output -raw backup_bucket 2>/dev/null || true)

if [ -n "$BACKUP_BUCKET" ]; then
  # Retain the versioned backup bucket. Terraform must stop managing these objects
  # before the full destroy, otherwise destroy fails on the non-empty bucket or strips
  # safety configuration off a bucket it is about to abandon.
  echo "==> retaining S3 backup bucket outside Terraform state: $BACKUP_BUCKET"
  for address in \
    aws_s3_bucket_public_access_block.backup \
    aws_s3_bucket_server_side_encryption_configuration.backup \
    aws_s3_bucket_versioning.backup \
    aws_s3_bucket.backup; do
    terraform state rm "$address" >/dev/null 2>&1 || true
  done
fi

# The reason two earlier destroys stalled: helm_release and kubernetes_* resources need
# a reachable Kubernetes API, and a dropped tunnel turns their destroy into a 5-minute
# hang followed by a failure that destroys nothing. They have no independent AWS billing
# and vanish with the cluster, so drop them from state and let destroy talk only to AWS.
echo "==> removing in-cluster resources from state so destroy needs only the AWS API"
while IFS= read -r addr; do
  [ -n "$addr" ] || continue
  echo "    state rm $addr"
  terraform state rm "$addr" >/dev/null 2>&1 || true
done < <(terraform state list 2>/dev/null | grep -E '^(helm_release|kubernetes_)' || true)

# Re-entrant: a transient DNS or network error can interrupt a run whose delete requests
# already landed, so a second pass simply continues from the new state.
echo "==> terraform destroy (retries once on transient failure)"
terraform destroy -auto-approve || {
  echo "WARNING: destroy did not complete; retrying once" >&2
  terraform destroy -auto-approve
}
cd ..

echo "==> teardown complete."
if [ -n "$BACKUP_BUCKET" ]; then
  echo "    retained S3 backup bucket: s3://$BACKUP_BUCKET"
  echo "    It is no longer managed by this Terraform state. Empty all object versions"
  echo "    and delete it manually only after confirming the backups are no longer needed."
fi
