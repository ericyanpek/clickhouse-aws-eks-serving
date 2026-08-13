#!/usr/bin/env bash
set -euo pipefail

# End-to-end storage selection benchmark. It runs the same ClickHouse version,
# 1x2 topology, resource envelope, client, schema, and queries against:
#   - i8g.4xlarge + local NVMe
#   - r8g.4xlarge + gp3
cd "$(dirname "$0")/.."

if [ -z "${CLICKHOUSE_ADMIN_PASSWORD:-}" ]; then
  echo "ERROR: set CLICKHOUSE_ADMIN_PASSWORD." >&2
  exit 1
fi

NS=${CLICKHOUSE_NAMESPACE:-clickhouse}
LOCAL_HOST=${LOCAL_CLICKHOUSE_HOST:-clickhouse-ch-local.clickhouse.svc.cluster.local}
EBS_HOST=${EBS_CLICKHOUSE_HOST:-clickhouse-ch-ebs.clickhouse.svc.cluster.local}
LOCAL_CLUSTER=${LOCAL_CLICKHOUSE_CLUSTER:-mainlocal}
EBS_CLUSTER=${EBS_CLICKHOUSE_CLUSTER:-mainebs}
SCALE_FACTOR=${STORAGE_SELECTION_SCALE_FACTOR:-10}
RESULT_ROOT=${RESULT_ROOT:-results/storage-selection}
RUN_TPCH=${RUN_TPCH:-false}

if ! [[ "$SCALE_FACTOR" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: STORAGE_SELECTION_SCALE_FACTOR must be a positive integer." >&2
  exit 1
fi
if [ "$RUN_TPCH" != "true" ] && [ "$RUN_TPCH" != "false" ]; then
  echo "ERROR: RUN_TPCH must be true or false." >&2
  exit 1
fi
if [ "$RUN_TPCH" = "true" ]; then
  echo "ERROR: RUN_TPCH=true is not implemented; refusing to produce a partial benchmark." >&2
  exit 1
fi

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
run_dir="$RESULT_ROOT/$timestamp"
mkdir -p "$run_dir"
started_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)

printf 'started_utc\t%s\nscale_factor\t%s\n' \
  "$started_utc" "$SCALE_FACTOR" >"$run_dir/run-metadata.tsv"

echo "==> [1/5] capturing infrastructure and collector baselines"
kubectl get nodes \
  -L workload,node.kubernetes.io/instance-type,topology.kubernetes.io/zone \
  >"$run_dir/nodes-before.txt"
kubectl -n "$NS" get pods,pvc -o wide >"$run_dir/pods-pvcs-before.txt"
kubectl get pv -o wide >"$run_dir/pvs-before.txt"
kubectl get volumeattachment -o wide >"$run_dir/volumeattachments-before.txt"
kubectl -n kube-system logs \
  -l app=storage-metrics-collector \
  --prefix --since=30s >"$run_dir/disk-counters-start.tsv"

common_env=(
  "CLICKHOUSE_ADMIN_PASSWORD=$CLICKHOUSE_ADMIN_PASSWORD"
  "EXPECTED_REPLICAS=2"
  "EXPECTED_BENCH_INSTANCE_TYPE=c7g.2xlarge"
  "LOCAL_CLICKHOUSE_HOST=$LOCAL_HOST"
  "EBS_CLICKHOUSE_HOST=$EBS_HOST"
  "LOCAL_CLICKHOUSE_CLUSTER=$LOCAL_CLUSTER"
  "EBS_CLICKHOUSE_CLUSTER=$EBS_CLUSTER"
)

echo "==> [2/5] official ClickBench 100M: warm, direct I/O, and concurrency"
env "${common_env[@]}" \
  CLICKHOUSE_DATABASE=storage_selection_small \
  CLICKBENCH_SCALE_FACTOR=1 \
  PAUSE_MERGES=true \
  QUERY_RUNS=3 \
  QPS_SECONDS=20 \
  RESULT_ROOT="$run_dir/clickbench-100m" \
  ./scripts/run-storage-comparison.sh

echo "==> [3/5] scaled ClickBench ${SCALE_FACTOR}x: storage-bound query and ingest phase"
env "${common_env[@]}" \
  CLICKHOUSE_DATABASE=storage_selection_large \
  CLICKBENCH_SCALE_FACTOR="$SCALE_FACTOR" \
  PAUSE_MERGES=true \
  QUERY_RUNS=2 \
  QPS_SECONDS=30 \
  QPS_RAMP_CONCURRENCIES="1 2 4 8" \
  RUN_FINAL_MERGE=true \
  FINAL_MERGE_BENCHMARK_SECONDS=300 \
  FINAL_MERGE_WARMUP_SECONDS=15 \
  RESULT_ROOT="$run_dir/clickbench-scaled" \
  ./scripts/run-storage-comparison.sh

echo "==> [4/5] publishing deterministic FINAL merge timing"
scaled_merge_file=
scaled_merge_file_count=0
while IFS= read -r candidate; do
  scaled_merge_file=$candidate
  scaled_merge_file_count=$((scaled_merge_file_count + 1))
done < <(find "$run_dir/clickbench-scaled" -mindepth 2 -maxdepth 2 \
  -type f -name merge-final.csv -print)
if [ "$scaled_merge_file_count" -ne 1 ]; then
  echo "ERROR: expected exactly one scaled merge-final.csv; found $scaled_merge_file_count." >&2
  exit 1
fi
cp "$scaled_merge_file" "$run_dir/merge-final.csv"

echo "TPC-H SF100 not executed in this run; ClickBench is the project-aligned primary dataset." \
  >"$run_dir/tpch-status.txt"

echo "==> [5/5] capturing final state and raw disk counters"
kubectl -n kube-system logs \
  -l app=storage-metrics-collector \
  --prefix --since-time="$started_utc" >"$run_dir/disk-counters-all.tsv"
kubectl -n "$NS" get pods,pvc -o wide >"$run_dir/pods-pvcs-after.txt"
kubectl get pv -o wide >"$run_dir/pvs-after.txt"
kubectl get volumeattachment -o wide >"$run_dir/volumeattachments-after.txt"
printf 'completed_utc\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  >>"$run_dir/run-metadata.tsv"

echo "==> storage selection benchmark complete: $run_dir"
