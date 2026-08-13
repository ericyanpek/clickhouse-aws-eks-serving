#!/usr/bin/env bash
set -euo pipefail

# Compare the existing i8g/local-NVMe CHI (`ch`) with the optional R8g/gp3 CHI
# (`ch-ebs`) using the same ClickBench dataset and query set.
cd "$(dirname "$0")/.."

NS=${CLICKHOUSE_NAMESPACE:-clickhouse}
CLIENT_POD=${COMPARISON_CLIENT_POD:-storage-comparison-client}
DATABASE_NAME=${CLICKHOUSE_DATABASE:-storage_compare}
LOCAL_HOST=${LOCAL_CLICKHOUSE_HOST:-clickhouse-ch.clickhouse.svc.cluster.local}
EBS_HOST=${EBS_CLICKHOUSE_HOST:-clickhouse-ch-ebs.clickhouse.svc.cluster.local}
LOCAL_CLUSTER=${LOCAL_CLICKHOUSE_CLUSTER:-main}
EBS_CLUSTER=${EBS_CLICKHOUSE_CLUSTER:-mainebs}
COMPARE_LOCAL=${COMPARE_LOCAL:-true}
PREPARE_DATA=${PREPARE_DATA:-true}
RUN_CLICKBENCH=${RUN_CLICKBENCH:-true}
RUN_QPS=${RUN_QPS:-true}
RUN_FINAL_MERGE=${RUN_FINAL_MERGE:-false}
QUERY_RUNS=${QUERY_RUNS:-3}
QPS_SECONDS=${QPS_SECONDS:-12}
QPS_CLASS_CONCURRENCY=${QPS_CLASS_CONCURRENCY:-8}
QPS_RAMP_CONCURRENCIES=${QPS_RAMP_CONCURRENCIES:-"1 2 4 8 16"}
FINAL_MERGE_BENCHMARK_SECONDS=${FINAL_MERGE_BENCHMARK_SECONDS:-300}
FINAL_MERGE_WARMUP_SECONDS=${FINAL_MERGE_WARMUP_SECONDS:-15}
CLICKBENCH_SCALE_FACTOR=${CLICKBENCH_SCALE_FACTOR:-1}
PAUSE_MERGES=${PAUSE_MERGES:-false}
EXPECTED_CLICKHOUSE_VERSION=${EXPECTED_CLICKHOUSE_VERSION:-25.3.14.14}
EXPECTED_REPLICAS=${EXPECTED_REPLICAS:-2}
EXPECTED_BENCH_INSTANCE_TYPE=${EXPECTED_BENCH_INSTANCE_TYPE:-c7g.2xlarge}
RESULT_ROOT=${RESULT_ROOT:-results/storage-comparison}
DATASET_URL=${CLICKBENCH_DATASET_URL:-https://datasets.clickhouse.com/hits_compatible/hits.parquet}
QUERIES_URL=${CLICKBENCH_QUERIES_URL:-https://raw.githubusercontent.com/ClickHouse/ClickBench/314839c510d59c62a27f9f16118460011df1f031/clickhouse/queries.sql}
QUERIES_SHA256=${CLICKBENCH_QUERIES_SHA256:-a7d6673357348ee9680443216b6f26f30d1dce9f313b419d38502417b2c2a219}
CLICKBENCH_BASE_ROWS=99997497

if [ -z "${CLICKHOUSE_ADMIN_PASSWORD:-}" ]; then
  echo "ERROR: set CLICKHOUSE_ADMIN_PASSWORD." >&2
  exit 1
fi
if ! [[ "$DATABASE_NAME" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
  echo "ERROR: CLICKHOUSE_DATABASE must be a valid unquoted ClickHouse identifier." >&2
  exit 1
fi
if ! [[ "$CLICKBENCH_SCALE_FACTOR" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: CLICKBENCH_SCALE_FACTOR must be a positive integer." >&2
  exit 1
fi
EXPECTED_ROWS=$((CLICKBENCH_BASE_ROWS * CLICKBENCH_SCALE_FACTOR))
if ! [[ "$QUERY_RUNS" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: QUERY_RUNS must be a positive integer." >&2
  exit 1
fi
if ! [[ "$QPS_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: QPS_SECONDS must be a positive integer." >&2
  exit 1
fi
if ! [[ "$QPS_CLASS_CONCURRENCY" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: QPS_CLASS_CONCURRENCY must be a positive integer." >&2
  exit 1
fi
if ! [[ "$EXPECTED_REPLICAS" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: EXPECTED_REPLICAS must be a positive integer." >&2
  exit 1
fi
if [ "$PREPARE_DATA" != "true" ] && [ "$PREPARE_DATA" != "false" ]; then
  echo "ERROR: PREPARE_DATA must be true or false." >&2
  exit 1
fi
if [ "$COMPARE_LOCAL" != "true" ] && [ "$COMPARE_LOCAL" != "false" ]; then
  echo "ERROR: COMPARE_LOCAL must be true or false." >&2
  exit 1
fi
for flag in RUN_CLICKBENCH RUN_QPS RUN_FINAL_MERGE; do
  value=${!flag}
  if [ "$value" != "true" ] && [ "$value" != "false" ]; then
    echo "ERROR: $flag must be true or false." >&2
    exit 1
  fi
done
if [ "$PAUSE_MERGES" != "true" ] && [ "$PAUSE_MERGES" != "false" ]; then
  echo "ERROR: PAUSE_MERGES must be true or false." >&2
  exit 1
fi
if ! [[ "$FINAL_MERGE_BENCHMARK_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: FINAL_MERGE_BENCHMARK_SECONDS must be a positive integer." >&2
  exit 1
fi
if ! [[ "$FINAL_MERGE_WARMUP_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: FINAL_MERGE_WARMUP_SECONDS must be a positive integer." >&2
  exit 1
fi
if [ "$RUN_FINAL_MERGE" = "true" ] &&
  { [ "$PAUSE_MERGES" != "true" ] || [ "$PREPARE_DATA" != "true" ]; }; then
  echo "ERROR: RUN_FINAL_MERGE=true requires PAUSE_MERGES=true and PREPARE_DATA=true." >&2
  exit 1
fi

profiles=(ebs_gp3)
hosts=("$EBS_HOST")
clusters=("$EBS_CLUSTER")
if [ "$COMPARE_LOCAL" = "true" ]; then
  profiles=(local_nvme ebs_gp3)
  hosts=("$LOCAL_HOST" "$EBS_HOST")
  clusters=("$LOCAL_CLUSTER" "$EBS_CLUSTER")
fi

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
result_dir="$RESULT_ROOT/$timestamp"
mkdir -p "$result_dir"
tmpdir=$(mktemp -d)
paused_merge_hosts=()
paused_merge_clusters=()
paused_merge_active=()
benchmark_pid=

cleanup() {
  local status=$?
  local i
  local cleanup_failed=0

  trap - EXIT
  set +e
  if [ -n "$benchmark_pid" ] && kill -0 "$benchmark_pid" 2>/dev/null; then
    kill "$benchmark_pid" 2>/dev/null
    wait "$benchmark_pid" 2>/dev/null
  fi
  if declare -F client >/dev/null 2>&1; then
    for i in "${!paused_merge_hosts[@]}"; do
      if [ "${paused_merge_active[$i]:-0}" = "1" ]; then
        echo "==> restoring merges for ${paused_merge_clusters[$i]}.$DATABASE_NAME.hits" >&2
        if client "${paused_merge_hosts[$i]}" --query \
          "SYSTEM START MERGES ON CLUSTER ${paused_merge_clusters[$i]} $DATABASE_NAME.hits"; then
          paused_merge_active[i]=0
        else
          echo "WARNING: failed to restore merges for ${paused_merge_clusters[$i]}.$DATABASE_NAME.hits" >&2
          cleanup_failed=1
        fi
      fi
    done
  fi
  rm -rf "$tmpdir"
  if [ "$status" -eq 0 ] && [ "$cleanup_failed" -ne 0 ]; then
    status=1
  fi
  exit "$status"
}
trap cleanup EXIT

echo "==> starting dedicated benchmark client"
kubectl apply -f manifests/60-storage-comparison-client.yaml
kubectl -n "$NS" wait --for=condition=Ready "pod/$CLIENT_POD" --timeout=10m

client_node=$(kubectl -n "$NS" get pod "$CLIENT_POD" -o jsonpath='{.spec.nodeName}')
client_instance_type=$(kubectl get node "$client_node" \
  -o jsonpath='{.metadata.labels.node\.kubernetes\.io/instance-type}')
if [ "$client_instance_type" != "$EXPECTED_BENCH_INSTANCE_TYPE" ]; then
  echo "ERROR: benchmark client runs on $client_instance_type; expected $EXPECTED_BENCH_INSTANCE_TYPE." >&2
  exit 1
fi
printf 'pod\tnode\tinstance_type\n%s\t%s\t%s\n' \
  "$CLIENT_POD" "$client_node" "$client_instance_type" \
  >"$result_dir/benchmark-client.tsv"

client() {
  local host=$1
  shift
  kubectl -n "$NS" exec -i "$CLIENT_POD" -c client -- \
    env CLICKHOUSE_PASSWORD="$CLICKHOUSE_ADMIN_PASSWORD" \
    clickhouse-client \
      --host "$host" \
      --port 9000 \
      --user admin \
      "$@"
}

pause_merges() {
  local host=$1
  local cluster=$2

  client "$host" --query \
    "SYSTEM STOP MERGES ON CLUSTER $cluster $DATABASE_NAME.hits"
  paused_merge_hosts+=("$host")
  paused_merge_clusters+=("$cluster")
  paused_merge_active+=(1)
}

resume_merges() {
  local host=$1
  local cluster=$2
  local i

  client "$host" --receive_timeout 7200 --query \
    "SYSTEM START MERGES ON CLUSTER $cluster $DATABASE_NAME.hits"
  for i in "${!paused_merge_hosts[@]}"; do
    if [ "${paused_merge_active[$i]:-0}" = "1" ] &&
      [ "${paused_merge_hosts[$i]}" = "$host" ] &&
      [ "${paused_merge_clusters[$i]}" = "$cluster" ]; then
      paused_merge_active[i]=0
      return
    fi
  done
}

printf 'profile\tcluster\tversion\thost\tconfigured_replicas\n' >"$result_dir/endpoints.tsv"
replica_counts=()
for i in "${!profiles[@]}"; do
  profile=${profiles[$i]}
  host=${hosts[$i]}
  cluster=${clusters[$i]}
  configured_replicas=$(client "$host" --query \
    "SELECT count() FROM system.clusters WHERE cluster='$cluster'" | tr -d '[:space:]')
  if [ "$configured_replicas" != "$EXPECTED_REPLICAS" ]; then
    echo "ERROR: $profile cluster $cluster exposes $configured_replicas replicas; expected $EXPECTED_REPLICAS." >&2
    exit 1
  fi
  clickhouse_version=$(client "$host" --query "SELECT version()" | tr -d '[:space:]')
  if [ "$clickhouse_version" != "$EXPECTED_CLICKHOUSE_VERSION" ]; then
    echo "ERROR: $profile runs ClickHouse $clickhouse_version; expected $EXPECTED_CLICKHOUSE_VERSION." >&2
    exit 1
  fi
  replica_counts+=("$configured_replicas")
  client "$host" --query \
    "SELECT '$profile', '$cluster', version(), hostName(), $configured_replicas FORMAT TSV" \
    >>"$result_dir/endpoints.tsv"
  client "$host" --query "
    SELECT
      name,
      path,
      formatReadableSize(total_space) AS total,
      formatReadableSize(free_space) AS free
    FROM system.disks
    FORMAT TSVWithNames" >"$result_dir/disks-$profile.tsv"
done

kubectl -n "$NS" get nodes \
  -l 'workload in (clickhouse-local-benchmark,clickhouse-ebs)' \
  -o wide >"$result_dir/nodes.txt"
kubectl -n "$NS" get pods,pvc \
  -l 'clickhouse.altinity.com/chi in (ch-local,ch-ebs)' \
  -o wide >"$result_dir/pods-pvcs.txt"
kubectl get pv -o wide >"$result_dir/pvs.txt"
kubectl get storageclass clickhouse-ebs-gp3 local-storage \
  -o yaml >"$result_dir/storage-classes.yaml"

write_reference_schema() {
  cat <<'SCHEMA'
WatchID|Int64
JavaEnable|Int16
Title|String
GoodEvent|Int16
EventTime|DateTime
EventDate|Date
CounterID|Int32
ClientIP|Int32
RegionID|Int32
UserID|Int64
CounterClass|Int16
OS|Int16
UserAgent|Int16
URL|String
Referer|String
IsRefresh|Int16
RefererCategoryID|Int16
RefererRegionID|Int32
URLCategoryID|Int16
URLRegionID|Int32
ResolutionWidth|Int16
ResolutionHeight|Int16
ResolutionDepth|Int16
FlashMajor|Int16
FlashMinor|Int16
FlashMinor2|String
NetMajor|Int16
NetMinor|Int16
UserAgentMajor|Int16
UserAgentMinor|String
CookieEnable|Int16
JavascriptEnable|Int16
IsMobile|Int16
MobilePhone|Int16
MobilePhoneModel|String
Params|String
IPNetworkID|Int32
TraficSourceID|Int16
SearchEngineID|Int16
SearchPhrase|String
AdvEngineID|Int16
IsArtifical|Int16
WindowClientWidth|Int16
WindowClientHeight|Int16
ClientTimeZone|Int16
ClientEventTime|DateTime
SilverlightVersion1|Int16
SilverlightVersion2|Int16
SilverlightVersion3|Int32
SilverlightVersion4|Int16
PageCharset|String
CodeVersion|Int32
IsLink|Int16
IsDownload|Int16
IsNotBounce|Int16
FUniqID|Int64
OriginalURL|String
HID|Int32
IsOldCounter|Int16
IsEvent|Int16
IsParameter|Int16
DontCountHits|Int16
WithHash|Int16
HitColor|String
LocalEventTime|DateTime
Age|Int16
Sex|Int16
Income|Int16
Interests|Int16
Robotness|Int16
RemoteIP|Int32
WindowName|Int32
OpenerName|Int32
HistoryLength|Int16
BrowserLanguage|String
BrowserCountry|String
SocialNetwork|String
SocialAction|String
HTTPError|Int16
SendTiming|Int32
DNSTiming|Int32
ConnectTiming|Int32
ResponseStartTiming|Int32
ResponseEndTiming|Int32
FetchTiming|Int32
SocialSourceNetworkID|Int16
SocialSourcePage|String
ParamPrice|Int64
ParamOrderID|String
ParamCurrency|String
ParamCurrencyID|Int16
OpenstatServiceName|String
OpenstatCampaignID|String
OpenstatAdID|String
OpenstatSourceID|String
UTMSource|String
UTMMedium|String
UTMCampaign|String
UTMContent|String
UTMTerm|String
FromTag|String
HasGCLID|Int16
RefererHash|Int64
URLHash|Int64
CLID|Int32
SCHEMA
}

validate_table() {
  local profile=$1
  local host=$2
  local expected_schema="$tmpdir/expected-schema.tsv"
  local actual_schema="$tmpdir/actual-schema-$profile.tsv"
  local expected_keys="$tmpdir/expected-keys.tsv"
  local actual_keys="$tmpdir/actual-keys-$profile.tsv"

  write_reference_schema | awk -F '|' '{ print $1 "\t" $2 }' >"$expected_schema"
  client "$host" --query "
    SELECT name, type
    FROM system.columns
    WHERE database = '$DATABASE_NAME' AND table = 'hits'
    ORDER BY position
    FORMAT TSVRaw" >"$actual_schema"
  if ! diff -u "$expected_schema" "$actual_schema"; then
    echo "ERROR: $profile ClickBench columns differ from the historical NVMe schema." >&2
    exit 1
  fi

  printf '%s\t%s\t%s\t%s\n' \
    ReplicatedMergeTree \
    'toYYYYMM(EventDate)' \
    'CounterID, EventDate, intHash32(UserID)' \
    'intHash32(UserID)' >"$expected_keys"
  client "$host" --query "
    SELECT engine, partition_key, sorting_key, sampling_key
    FROM system.tables
    WHERE database = '$DATABASE_NAME' AND name = 'hits'
    FORMAT TSVRaw" >"$actual_keys"
  if ! diff -u "$expected_keys" "$actual_keys"; then
    echo "ERROR: $profile ClickBench engine or keys differ from the historical NVMe table." >&2
    exit 1
  fi
}

create_table() {
  local profile=$1
  local host=$2
  local cluster=$3
  local keeper_path="/clickhouse/storage-comparison/$DATABASE_NAME/$profile/{shard}/hits"
  local schema_file="$tmpdir/schema-$profile.tsv"

  write_reference_schema >"$schema_file"

  {
    cat <<SQL
CREATE DATABASE IF NOT EXISTS $DATABASE_NAME ON CLUSTER $cluster;

CREATE TABLE IF NOT EXISTS $DATABASE_NAME.hits ON CLUSTER $cluster
(
SQL
    awk -F '|' '
      NF >= 2 {
        names[++count] = $1
        types[count] = $2
      }
      END {
        for (i = 1; i <= count; i++) {
          printf "    `%s` %s%s\n", names[i], types[i], (i < count ? "," : "")
        }
      }
    ' "$schema_file"
    cat <<SQL
)
ENGINE = ReplicatedMergeTree(
    '$keeper_path',
    '{replica}'
)
PARTITION BY toYYYYMM(EventDate)
ORDER BY (CounterID, EventDate, intHash32(UserID))
SAMPLE BY intHash32(UserID)
SETTINGS index_granularity = 8192;
SQL
  } >"$tmpdir/create-$profile.sql"

  client "$host" --multiquery <"$tmpdir/create-$profile.sql"
  validate_table "$profile" "$host"
}

wait_for_replication() {
  local host=$1
  local cluster=$2
  local expected_replicas=$3
  local deadline=$((SECONDS + 3600))
  local queue

  while true; do
    queue=$(client "$host" --query \
      "SELECT
         count() = $expected_replicas
         AND min(active_replicas) = $expected_replicas
         AND max(is_readonly) = 0
         AND (
           SELECT count()
           FROM clusterAllReplicas('$cluster', system.replication_queue)
           WHERE database='$DATABASE_NAME'
             AND table='hits'
             AND type NOT IN ('MERGE_PARTS', 'MUTATE_PART')
         ) = 0
       FROM clusterAllReplicas('$cluster', system.replicas)
       WHERE database='$DATABASE_NAME' AND table='hits'" \
      | tr -d '[:space:]')
    if [ "${queue:-0}" = "1" ]; then
      return
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "ERROR: replication queue did not drain for $cluster within 1 hour." >&2
      exit 1
    fi
    sleep 15
  done
}

prepare_profile() {
  local profile=$1
  local host=$2
  local cluster=$3
  local expected_replicas=$4
  local count
  local loaded_copies
  local copy_index
  local watch_offset
  local user_offset
  local started
  local insert_elapsed
  local ready_elapsed

  echo "==> preparing ClickBench on $profile"
  create_table "$profile" "$host" "$cluster"
  count=$(client "$host" --database "$DATABASE_NAME" --query "SELECT count() FROM hits" \
    | tr -d '[:space:]')

  if [ "$count" -gt "$EXPECTED_ROWS" ] || [ $((count % CLICKBENCH_BASE_ROWS)) -ne 0 ]; then
    echo "ERROR: $profile has $count rows; expected a resumable multiple of $CLICKBENCH_BASE_ROWS up to $EXPECTED_ROWS." >&2
    exit 1
  fi
  loaded_copies=$((count / CLICKBENCH_BASE_ROWS))

  if [ "$PAUSE_MERGES" = "true" ]; then
    pause_merges "$host" "$cluster"
  fi

  for copy_index in $(seq "$loaded_copies" $((CLICKBENCH_SCALE_FACTOR - 1))); do
    watch_offset=$((copy_index * 100000000))
    user_offset=$((copy_index * 1000000000000))
    started=$SECONDS
    client "$host" \
      --database "$DATABASE_NAME" \
      --query_id "storage_selection_load_${profile}_${copy_index}" \
      --query "
      INSERT INTO hits
      SELECT * REPLACE(
        WatchID + $watch_offset AS WatchID,
        UserID + $user_offset AS UserID,
        FUniqID + $user_offset AS FUniqID,
        toDate(EventDate) AS EventDate,
        toDateTime(EventTime) AS EventTime,
        toDateTime(ClientEventTime) AS ClientEventTime,
        toDateTime(LocalEventTime) AS LocalEventTime
      )
      FROM url('$DATASET_URL', 'Parquet')
      SETTINGS
        schema_inference_make_columns_nullable=0,
        max_insert_threads=14,
        input_format_parquet_max_block_size=65536"
    insert_elapsed=$((SECONDS - started))
    wait_for_replication "$host" "$cluster" "$expected_replicas"
    ready_elapsed=$((SECONDS - started))
    printf '%s,%s,%s,%s\n' "$profile" "$copy_index" "$insert_elapsed" "$ready_elapsed" \
      >>"$result_dir/load-seconds.csv"
  done
  wait_for_replication "$host" "$cluster" "$expected_replicas"

  client "$host" --database "$DATABASE_NAME" --query "
    SELECT
      '$profile' AS profile,
      sum(rows) AS rows,
      formatReadableSize(sum(bytes_on_disk)) AS bytes_on_disk
    FROM system.parts
    WHERE active AND database='$DATABASE_NAME' AND table='hits'
    FORMAT TSVWithNames" >"$result_dir/dataset-$profile.tsv"
}

printf 'profile,copy_index,insert_seconds,replicas_ready_seconds\n' >"$result_dir/load-seconds.csv"
if [ "$PREPARE_DATA" = "true" ]; then
  for i in "${!profiles[@]}"; do
    prepare_profile "${profiles[$i]}" "${hosts[$i]}" "${clusters[$i]}" "${replica_counts[$i]}"
  done
fi

for i in "${!profiles[@]}"; do
  profile=${profiles[$i]}
  host=${hosts[$i]}
  validate_table "$profile" "$host"
  rows=$(client "$host" --database "$DATABASE_NAME" --query "SELECT count() FROM hits" \
    | tr -d '[:space:]')
  if [ "$rows" != "$EXPECTED_ROWS" ]; then
    echo "ERROR: $profile has $rows ClickBench rows; expected $EXPECTED_ROWS." >&2
    exit 1
  fi
  client "$host" --query "
    SELECT
      hostName(),
      count() AS active_parts,
      sum(marks) AS marks,
      sum(rows) AS rows,
      sum(bytes_on_disk) AS bytes_on_disk
    FROM clusterAllReplicas('${clusters[$i]}', system.parts)
    WHERE active AND database = '$DATABASE_NAME' AND table = 'hits'
    GROUP BY hostName()
    ORDER BY hostName()
    FORMAT TSVWithNames" >"$result_dir/parts-$profile.tsv"
done

if [ "$RUN_CLICKBENCH" = "true" ]; then
  echo "==> downloading the official 43-query ClickBench suite"
  curl --silent --show-error --fail --location "$QUERIES_URL" -o "$tmpdir/queries.sql"
  actual_queries_sha256=$(shasum -a 256 "$tmpdir/queries.sql" | awk '{ print $1 }')
  if [ "$actual_queries_sha256" != "$QUERIES_SHA256" ]; then
    echo "ERROR: queries.sql SHA-256 is $actual_queries_sha256; expected $QUERIES_SHA256." >&2
    exit 1
  fi
  cp "$tmpdir/queries.sql" "$result_dir/clickbench-queries.sql"
  printf '%s  %s\n' "$actual_queries_sha256" clickbench-queries.sql \
    >"$result_dir/clickbench-queries.sha256"
  query_count=$(grep -cve '^[[:space:]]*$' "$tmpdir/queries.sql")
  if [ "$query_count" != "43" ]; then
    echo "ERROR: downloaded ClickBench suite contains $query_count non-empty lines; expected 43." >&2
    exit 1
  fi

  printf 'profile,mode,qid' >"$result_dir/clickbench.csv"
  for run in $(seq 1 "$QUERY_RUNS"); do
    printf ',run%s_s' "$run" >>"$result_dir/clickbench.csv"
  done
  printf ',best_s\n' >>"$result_dir/clickbench.csv"

  run_one_query() {
    local host=$1
    local mode=$2
    local query=$3
    local output

    if [ "$mode" = "direct_io" ]; then
      output=$(printf '%s\n' "$query" | client "$host" \
        --database "$DATABASE_NAME" \
        --format Null \
        --time \
        --min_bytes_to_use_direct_io=1 2>&1 | tail -n 1)
    else
      output=$(printf '%s\n' "$query" | client "$host" \
        --database "$DATABASE_NAME" \
        --format Null \
        --time 2>&1 | tail -n 1)
    fi

    if ! [[ "$output" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      echo "ERROR: unexpected timing output: $output" >&2
      return 1
    fi
    printf '%s' "$output"
  }

  for i in "${!profiles[@]}"; do
    profile=${profiles[$i]}
    host=${hosts[$i]}

    for mode in warm direct_io; do
      qid=0
      while IFS= read -r query; do
        [ -n "$query" ] || continue
        qid=$((qid + 1))
        printf '%s,%s,Q%s' "$profile" "$mode" "$qid" >>"$result_dir/clickbench.csv"
        best=
        for run in $(seq 1 "$QUERY_RUNS"); do
          elapsed=$(run_one_query "$host" "$mode" "$query")
          printf ',%s' "$elapsed" >>"$result_dir/clickbench.csv"
          if [ -z "$best" ] || awk -v new="$elapsed" -v old="$best" 'BEGIN { exit !(new < old) }'; then
            best=$elapsed
          fi
        done
        printf ',%s\n' "$best" >>"$result_dir/clickbench.csv"
        echo "    $profile $mode Q$qid best=${best}s"
      done <"$tmpdir/queries.sql"
    done
  done
fi

run_qps_case() {
  local profile=$1
  local host=$2
  local name=$3
  local query=$4
  local concurrencies=$5
  local concurrency

  for concurrency in $concurrencies; do
    log="$result_dir/qps-${profile}-${name}-c${concurrency}.txt"
    printf '%s\n' "$query" | kubectl -n "$NS" exec -i "$CLIENT_POD" -c client -- \
      env CLICKHOUSE_PASSWORD="$CLICKHOUSE_ADMIN_PASSWORD" \
      clickhouse-benchmark \
        --host "$host" \
        --port 9000 \
        --user admin \
        --database "$DATABASE_NAME" \
        --concurrency "$concurrency" \
        --timelimit "$QPS_SECONDS" >"$log" 2>&1
  done
}

if [ "$RUN_QPS" = "true" ]; then
  echo "==> running the project QPS query classes"
  cat >"$result_dir/qps-queries.sql" <<'SQL'
-- point
SELECT count() FROM hits WHERE CounterID=62;
-- filtered_aggregate
SELECT RegionID, count() FROM hits WHERE CounterID=62 GROUP BY RegionID ORDER BY count() DESC LIMIT 10;
-- connection
SELECT 1;
-- full_scan_ramp
SELECT RegionID, count() FROM hits GROUP BY RegionID ORDER BY count() DESC LIMIT 10;
SQL
  for i in "${!profiles[@]}"; do
    profile=${profiles[$i]}
    host=${hosts[$i]}
    run_qps_case "$profile" "$host" point \
      "SELECT count() FROM hits WHERE CounterID=62" \
      "$QPS_CLASS_CONCURRENCY"
    run_qps_case "$profile" "$host" filtered_aggregate \
      "SELECT RegionID, count() FROM hits WHERE CounterID=62 GROUP BY RegionID ORDER BY count() DESC LIMIT 10" \
      "$QPS_CLASS_CONCURRENCY"
    run_qps_case "$profile" "$host" connection \
      "SELECT 1" \
      "$QPS_CLASS_CONCURRENCY"
    run_qps_case "$profile" "$host" full_scan_ramp \
      "SELECT RegionID, count() FROM hits GROUP BY RegionID ORDER BY count() DESC LIMIT 10" \
      "$QPS_RAMP_CONCURRENCIES"
  done
fi

if [ "$RUN_FINAL_MERGE" = "true" ]; then
  echo "==> running concurrent full-scan load during deterministic FINAL merge"
  printf 'profile,optimize_seconds\n' >"$result_dir/merge-final.csv"
  full_scan='SELECT RegionID, count() FROM hits GROUP BY RegionID ORDER BY count() DESC LIMIT 10'

  for i in "${!profiles[@]}"; do
    profile=${profiles[$i]}
    host=${hosts[$i]}
    cluster=${clusters[$i]}
    client "$host" --query "
      SELECT hostName(), count() AS active_parts, sum(rows), sum(bytes_on_disk)
      FROM clusterAllReplicas('$cluster', system.parts)
      WHERE active AND database='$DATABASE_NAME' AND table='hits'
      GROUP BY hostName()
      ORDER BY hostName()
      FORMAT TSVWithNames" >"$result_dir/parts-before-merge-$profile.tsv"

    printf '%s\n' "$full_scan" | kubectl -n "$NS" exec -i "$CLIENT_POD" -c client -- \
      env CLICKHOUSE_PASSWORD="$CLICKHOUSE_ADMIN_PASSWORD" \
      clickhouse-benchmark \
        --host "$host" \
        --port 9000 \
        --user admin \
        --database "$DATABASE_NAME" \
        --concurrency 4 \
        --timelimit "$FINAL_MERGE_BENCHMARK_SECONDS" \
        --continue_on_errors \
        >"$result_dir/qps-during-merge-$profile.txt" 2>&1 &
    benchmark_pid=$!
    sleep "$FINAL_MERGE_WARMUP_SECONDS"

    started=$SECONDS
    resume_merges "$host" "$cluster"
    client "$host" \
      --receive_timeout 7200 \
      --distributed_ddl_task_timeout 7200 \
      --query "OPTIMIZE TABLE $DATABASE_NAME.hits ON CLUSTER $cluster FINAL"
    optimize_seconds=$((SECONDS - started))
    printf '%s,%s\n' "$profile" "$optimize_seconds" >>"$result_dir/merge-final.csv"

    wait "$benchmark_pid"
    benchmark_pid=
    client "$host" --query "
      SELECT hostName(), count() AS active_parts, sum(rows), sum(bytes_on_disk)
      FROM clusterAllReplicas('$cluster', system.parts)
      WHERE active AND database='$DATABASE_NAME' AND table='hits'
      GROUP BY hostName()
      ORDER BY hostName()
      FORMAT TSVWithNames" >"$result_dir/parts-after-merge-$profile.tsv"
  done
fi

echo "==> comparison complete: $result_dir"
if [ "$RUN_CLICKBENCH" = "true" ]; then
  echo "Primary result: $result_dir/clickbench.csv"
fi
