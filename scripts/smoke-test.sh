#!/usr/bin/env bash
set -euo pipefail
# Validate distributed writes and every replica, using a disposable database.
CHI=${CLICKHOUSE_CHI:-ebs}
NS=${CLICKHOUSE_NAMESPACE:-ck-$CHI}
LOGICAL_CLUSTER=main
POD=$(kubectl -n "$NS" get pods -l "clickhouse.altinity.com/chi=$CHI" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort | awk 'NR == 1')
[ -n "$POD" ] || { echo "ERROR: no ClickHouse pod in $NS for $CHI" >&2; exit 1; }

CH_AUTH=(--user default)
if [ -n "${CLICKHOUSE_ADMIN_PASSWORD:-}" ]; then
  CH_AUTH=(--user admin --password "$CLICKHOUSE_ADMIN_PASSWORD")
else
  echo "WARNING: connecting as default; admin credentials are not verified." >&2
fi
run() {
  kubectl -n "$NS" exec "$POD" -c clickhouse -- clickhouse-client \
    "${CH_AUTH[@]}" --receive_timeout 60 --distributed_ddl_task_timeout 60 "$@"
}

SHARDS=$(kubectl -n "$NS" get chi "$CHI" -o jsonpath='{.spec.configuration.clusters[0].layout.shardsCount}')
REPLICAS=$(kubectl -n "$NS" get chi "$CHI" -o jsonpath='{.spec.configuration.clusters[0].layout.replicasCount}')
TOPOLOGY=$(run -q "SELECT shard_num, replica_num, host_name FROM system.clusters
  WHERE cluster='$LOGICAL_CLUSTER' ORDER BY shard_num, replica_num FORMAT TSV")
# A matching total alone can hide a missing shard or a duplicate replica.
printf '%s\n' "$TOPOLOGY" | python3 -c '
import sys
shards, replicas = int(sys.argv[1]), int(sys.argv[2])
rows = [line.rstrip("\n").split("\t") for line in sys.stdin if line.strip()]
expected = {(s, r) for s in range(1, shards+1) for r in range(1, replicas+1)}
if shards < 1 or replicas < 1 or any(len(row) != 3 for row in rows):
    sys.exit("ERROR: invalid declared or observed topology")
observed = {(int(s), int(r)) for s, r, host in rows}
if observed != expected or len(rows) != len(expected) or len({r[2] for r in rows}) != len(rows):
    sys.exit("ERROR: system.clusters does not match the declared shard/replica topology")
' "$SHARDS" "$REPLICAS"

# A unique name makes repeated/concurrent runs independent of deduplication windows.
DB="smoke_$(python3 -c 'import uuid; print(uuid.uuid4().hex)')"
cleanup() {
  local status=$?
  trap - EXIT
  if ! run -q "DROP DATABASE IF EXISTS $DB ON CLUSTER $LOGICAL_CLUSTER SYNC"; then
    echo "ERROR: cleanup failed; remove database $DB after checking cluster health." >&2
    [ "$status" -ne 0 ] || status=1
  fi
  exit "$status"
}
trap cleanup EXIT
run -q "CREATE DATABASE $DB ON CLUSTER $LOGICAL_CLUSTER"
run -q "CREATE TABLE $DB.t_local ON CLUSTER $LOGICAL_CLUSTER (id UInt64, v String)
  ENGINE=ReplicatedMergeTree('/clickhouse/tables/{shard}/$DB/t_local','{replica}') ORDER BY id"
run -q "CREATE TABLE $DB.t_dist ON CLUSTER $LOGICAL_CLUSTER AS $DB.t_local
  ENGINE=Distributed($LOGICAL_CLUSTER, $DB, t_local, id)"
ROWS=$((1000 * SHARDS))
run -q "INSERT INTO $DB.t_dist SELECT number, toString(number) FROM numbers($ROWS)
  SETTINGS insert_distributed_sync=1"

# Synchronize every host first; compare each replica with replica 1 of its own shard.
# Shard-local counts need not equal the global row count or each other.
while IFS=$'\t' read -r shard replica host; do
  run --host "$host" -q "SYSTEM SYNC REPLICA $DB.t_local"
done <<<"$TOPOLOGY"

previous_shard=0
expected=
while IFS=$'\t' read -r shard replica host; do
  actual=$(run --host "$host" -q "SELECT count(), sum(id), sum(cityHash64(v)) FROM $DB.t_local FORMAT TSV")
  if [ "$shard" != "$previous_shard" ]; then
    expected=$actual
    previous_shard=$shard
    [ "${actual%%$'\t'*}" -gt 0 ] || { echo "ERROR: shard $shard received no rows" >&2; exit 1; }
  fi
  [ "$actual" = "$expected" ] || {
    echo "ERROR: shard $shard replica $replica differs from its peer" >&2; exit 1;
  }
  health=$(run --host "$host" -q "SELECT count(), countIf(is_readonly OR is_session_expired OR queue_size > 0)
    FROM system.replicas WHERE database='$DB' AND table='t_local' FORMAT TSV")
  [ "$health" = $'1\t0' ] || { echo "ERROR: unhealthy replication on $host: $health" >&2; exit 1; }
  echo "Verified shard=$shard replica=$replica host=$host"
done <<<"$TOPOLOGY"

TOTAL=$(run -q "SELECT count(), uniqExact(id), sum(id) FROM $DB.t_dist FORMAT TSV")
EXPECTED=$(printf '%s\t%s\t%s' "$ROWS" "$ROWS" "$((ROWS * (ROWS - 1) / 2))")
[ "$TOTAL" = "$EXPECTED" ] || { echo "ERROR: distributed rows/IDs differ: $TOTAL" >&2; exit 1; }
# Run cleanup before announcing success, so a leaked test database fails the test.
run -q "DROP DATABASE $DB ON CLUSTER $LOGICAL_CLUSTER SYNC"
trap - EXIT
echo "SMOKE TEST PASSED ($NS/$CHI, ${SHARDS}x${REPLICAS}, all replicas checked)"
