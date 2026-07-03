#!/usr/bin/env bash
set -euo pipefail
# End-to-end validation of the ClickHouse cluster. Run after deploy.sh.
NS=clickhouse
POD=chi-ch-main-0-0

run() { kubectl -n "$NS" exec "$POD" -c clickhouse -- clickhouse-client -q "$1"; }

echo "==> cluster topology"
run "SELECT cluster, shard_num, replica_num, host_name FROM system.clusters WHERE cluster='main' ORDER BY shard_num, replica_num"

echo "==> create replicated + distributed tables"
run "CREATE TABLE IF NOT EXISTS default.t_local ON CLUSTER main (id UInt64, v String)
     ENGINE=ReplicatedMergeTree('/clickhouse/tables/{shard}/t_local','{replica}') ORDER BY id"
run "CREATE TABLE IF NOT EXISTS default.t_dist ON CLUSTER main AS default.t_local
     ENGINE=Distributed(main, default, t_local, rand())"

echo "==> insert via distributed table"
run "INSERT INTO default.t_dist SELECT number, toString(number) FROM numbers(1000)"
sleep 3

echo "==> verify replication (query the OTHER replica of shard 0)"
kubectl -n "$NS" exec chi-ch-main-0-1 -c clickhouse -- clickhouse-client -q \
  "SELECT count() FROM default.t_local"

echo "==> total across shards via distributed"
DIST_COUNT=$(run "SELECT count() FROM default.t_dist" | tr -d '[:space:]')
echo "distributed count = $DIST_COUNT"

echo "==> replication health"
run "SELECT database, table, is_readonly, absolute_delay FROM system.replicas WHERE table='t_local'"
REPLICA_ROWS=$(run "SELECT count() FROM system.replicas WHERE table='t_local'" | tr -d '[:space:]')

if [ "$DIST_COUNT" = "1000" ] && [ "$REPLICA_ROWS" -gt 0 ] 2>/dev/null; then
  echo "==> SMOKE TEST PASSED (distributed count=1000, replicas registered=$REPLICA_ROWS)"
else
  echo "==> SMOKE TEST FAILED (distributed count=$DIST_COUNT expected 1000; replicas=$REPLICA_ROWS expected >0)" >&2
  exit 1
fi
