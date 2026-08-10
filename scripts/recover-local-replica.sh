#!/usr/bin/env bash
set -euo pipefail

# Rebind one permanently lost ClickHouse local-NVMe replica to a fresh local PV.
# This deliberately deletes the failed replica's Pod, PVC, and stale PV.
NS=${CLICKHOUSE_NAMESPACE:-clickhouse}
POD=${1:-}
PVC=${2:-}
TIMEOUT=${RECOVERY_TIMEOUT:-2h}
OPERATOR_NS=${CLICKHOUSE_OPERATOR_NAMESPACE:-kube-system}
OPERATOR_DEPLOYMENT=${CLICKHOUSE_OPERATOR_DEPLOYMENT:-altinity-clickhouse-operator}
OPERATOR_SCALED=false

restore_operator() {
  if [ "$OPERATOR_SCALED" = "true" ]; then
    echo "==> restoring operator deployment to $OPERATOR_REPLICAS replica(s)"
    kubectl -n "$OPERATOR_NS" scale "deployment/$OPERATOR_DEPLOYMENT" \
      --replicas="$OPERATOR_REPLICAS" >/dev/null || true
  fi
}
trap restore_operator EXIT

usage() {
  echo "Usage: CONFIRM_REPLICA_DATA_LOSS=yes $0 <failed-pod> [data-pvc]" >&2
}

if [ -z "$POD" ]; then
  usage
  exit 2
fi

if [ "${CONFIRM_REPLICA_DATA_LOSS:-}" != "yes" ]; then
  echo "ERROR: this deletes local replica data." >&2
  echo "Re-run with CONFIRM_REPLICA_DATA_LOSS=yes after verifying the pod's node is permanently lost." >&2
  exit 1
fi

if kubectl -n "$NS" get pod "$POD" >/dev/null 2>&1; then
  POD_READY=$(kubectl -n "$NS" get pod "$POD" \
    -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}')
  if [ "$POD_READY" = "True" ]; then
    echo "ERROR: $NS/$POD is Ready; refusing to delete a healthy replica." >&2
    exit 1
  fi

  if [ -z "$PVC" ]; then
    while IFS= read -r candidate; do
      [ -n "$candidate" ] || continue
      storage_class=$(kubectl -n "$NS" get pvc "$candidate" -o jsonpath='{.spec.storageClassName}')
      if [ "$storage_class" = "local-storage" ]; then
        if [ -n "$PVC" ]; then
          echo "ERROR: multiple local-storage PVCs found; pass the data PVC explicitly." >&2
          exit 1
        fi
        PVC=$candidate
      fi
    done < <(kubectl -n "$NS" get pod "$POD" \
      -o jsonpath='{range .spec.volumes[?(@.persistentVolumeClaim)]}{.persistentVolumeClaim.claimName}{"\n"}{end}')
  fi
elif [ -z "$PVC" ]; then
  echo "ERROR: pod $NS/$POD no longer exists; pass its data PVC as the second argument." >&2
  exit 1
fi

if [ -z "$PVC" ]; then
  echo "ERROR: could not infer a local-storage PVC for $NS/$POD." >&2
  usage
  exit 1
fi

STORAGE_CLASS=$(kubectl -n "$NS" get pvc "$PVC" -o jsonpath='{.spec.storageClassName}')
if [ "$STORAGE_CLASS" != "local-storage" ]; then
  echo "ERROR: PVC $NS/$PVC uses $STORAGE_CLASS, not local-storage; refusing destructive recovery." >&2
  exit 1
fi

CHI=$(kubectl -n "$NS" get pvc "$PVC" \
  -o jsonpath='{.metadata.labels.clickhouse\.altinity\.com/chi}')
if [ -z "$CHI" ]; then
  echo "ERROR: PVC $NS/$PVC has no ClickHouseInstallation label; refusing destructive recovery." >&2
  exit 1
fi

READY_PEERS=$(kubectl -n "$NS" get pods -l "clickhouse.altinity.com/chi=$CHI" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}' \
  | awk -v target="$POD" '$1 != target && $2 == "True" { count++ } END { print count + 0 }')
if [ "$READY_PEERS" -lt 1 ]; then
  echo "ERROR: no other Ready ClickHouse replica is available; restore from S3 instead." >&2
  exit 1
fi

PV=$(kubectl -n "$NS" get pvc "$PVC" -o jsonpath='{.spec.volumeName}')
if [ -z "$PV" ]; then
  echo "ERROR: PVC $NS/$PVC is not bound to a PV." >&2
  exit 1
fi

OPERATOR_REPLICAS=$(kubectl -n "$OPERATOR_NS" get "deployment/$OPERATOR_DEPLOYMENT" \
  -o jsonpath='{.spec.replicas}')
if [ -z "$OPERATOR_REPLICAS" ] || [ "$OPERATOR_REPLICAS" -lt 1 ]; then
  echo "ERROR: operator deployment has no active replicas; refusing recovery." >&2
  exit 1
fi

echo "==> recovering $NS/$POD from $READY_PEERS healthy peer replica(s)"
echo "    deleting PVC $PVC and stale local PV $PV"
echo "==> temporarily pausing the operator to prevent Pod/PVC recreation races"
kubectl -n "$OPERATOR_NS" scale "deployment/$OPERATOR_DEPLOYMENT" --replicas=0
OPERATOR_SCALED=true
kubectl -n "$OPERATOR_NS" rollout status "deployment/$OPERATOR_DEPLOYMENT" --timeout=2m

kubectl -n "$NS" delete pod "$POD" --ignore-not-found --wait=true
kubectl -n "$NS" delete pvc "$PVC" --wait=true
kubectl delete pv "$PV" --ignore-not-found --wait=true

echo "==> restoring operator deployment to $OPERATOR_REPLICAS replica(s)"
kubectl -n "$OPERATOR_NS" scale "deployment/$OPERATOR_DEPLOYMENT" \
  --replicas="$OPERATOR_REPLICAS"
OPERATOR_SCALED=false
kubectl -n "$OPERATOR_NS" rollout status "deployment/$OPERATOR_DEPLOYMENT" --timeout=5m

echo "==> waiting for the operator to recreate PVC $PVC"
deadline=$((SECONDS + 300))
until kubectl -n "$NS" get pvc "$PVC" >/dev/null 2>&1; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "ERROR: PVC $NS/$PVC was not recreated within 5 minutes; inspect the CHI and operator logs." >&2
    exit 1
  fi
  sleep 5
done

kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Bound "pvc/$PVC" --timeout="$TIMEOUT"
kubectl -n "$NS" wait --for=condition=Ready "pod/$POD" --timeout="$TIMEOUT"

echo "==> pod is Ready; verify replica queues have drained before declaring recovery complete:"
echo "    kubectl -n $NS exec $POD -c clickhouse -- clickhouse-client -q \\"
echo "      \"SELECT database, table, is_readonly, absolute_delay, queue_size FROM system.replicas FORMAT PrettyCompact\""
