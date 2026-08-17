#!/usr/bin/env bash
set -euo pipefail
# End-to-end validation of one ClickHouse cluster. Run after deploy.sh, or standalone:
#   CLICKHOUSE_NAMESPACE=ck-ebs CLICKHOUSE_CHI=ebs ./scripts/smoke-test.sh
NS=${CLICKHOUSE_NAMESPACE:-clickhouse}
# CLICKHOUSE_CHI is the CHI *resource* name (metadata.name), used to find the pods.
CHI=${CLICKHOUSE_CHI:-ch}
# The CHI's internal logical cluster name is a separate concept and is fixed to 'main'
# by 20-clickhouse-chi.yaml.tmpl. Conflating the two silently breaks every
# `ON CLUSTER` statement and every system.clusters lookup below.
LOGICAL_CLUSTER=main

# Find the pod by label rather than by an assumed name: the operator's naming scheme
# (chi-<chi>-<cluster>-<shard>-<replica>) is an implementation detail.
POD=$(kubectl -n "$NS" get pods -l "clickhouse.altinity.com/chi=$CHI" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null |
  sort | awk 'NR == 1')
[ -n "$POD" ] || {
  echo "ERROR: no ClickHouse pod found in namespace $NS for CHI '$CHI'" >&2
  exit 1
}
echo "==> target: namespace=$NS chi=$CHI pod=$POD logical cluster=$LOGICAL_CLUSTER"

# Authenticate as admin when a password is supplied, so the test actually exercises the
# rendered credential. Connecting as the default user would let a botched
# REPLACE_WITH_ADMIN_SHA256 substitution pass unnoticed: the cluster would look healthy
# here and reject every real client afterwards.
#
# The password is passed through the environment rather than argv so it never appears in
# a process listing.
CH_AUTH=()
if [ -n "${CLICKHOUSE_ADMIN_PASSWORD:-}" ]; then
  CH_AUTH=(--user admin --password "$CLICKHOUSE_ADMIN_PASSWORD")
  echo "==> authenticating as admin"
else
  echo "==> WARNING: CLICKHOUSE_ADMIN_PASSWORD not set; connecting as the default user."
  echo "    The rendered admin credential is therefore NOT verified by this run."
fi

run() { kubectl -n "$NS" exec "$POD" -c clickhouse -- clickhouse-client "${CH_AUTH[@]}" -q "$1"; }
run_on() { kubectl -n "$NS" exec "$1" -c clickhouse -- clickhouse-client "${CH_AUTH[@]}" -q "$2"; }

echo "==> cluster topology"
run "SELECT cluster, shard_num, replica_num, host_name FROM system.clusters WHERE cluster='$LOGICAL_CLUSTER' ORDER BY shard_num, replica_num"

echo "==> create replicated + distributed tables"
run "CREATE TABLE IF NOT EXISTS default.t_local ON CLUSTER $LOGICAL_CLUSTER (id UInt64, v String)
     ENGINE=ReplicatedMergeTree('/clickhouse/tables/{shard}/t_local','{replica}') ORDER BY id"
run "CREATE TABLE IF NOT EXISTS default.t_dist ON CLUSTER $LOGICAL_CLUSTER AS default.t_local
     ENGINE=Distributed($LOGICAL_CLUSTER, default, t_local, rand())"

echo "==> insert via distributed table"
run "INSERT INTO default.t_dist SELECT number, toString(number) FROM numbers(1000)"
sleep 3

# Replication is only observable with a second replica of the same shard. The operator
# names it chi-<chi>-<cluster>-<shard>-<replica>, so shard 0's peer is ...-0-1.
PEER="chi-$CHI-$LOGICAL_CLUSTER-0-1"
if kubectl -n "$NS" get pod "$PEER" >/dev/null 2>&1; then
  echo "==> verify replication (query the OTHER replica of shard 0: $PEER)"
  run_on "$PEER" "SELECT count() FROM default.t_local"
else
  echo "==> single replica per shard ($PEER absent); skipping cross-replica check"
fi

# Total across all shards must still be 1000: with 1 shard the Distributed table is a
# single-hop passthrough, with N shards it fans out and sums the parts.
echo "==> total via distributed table"
DIST_COUNT=$(run "SELECT count() FROM default.t_dist" | tr -d '[:space:]')
echo "distributed count = $DIST_COUNT"

echo "==> replication health"
run "SELECT database, table, is_readonly, absolute_delay FROM system.replicas WHERE table='t_local'"
REPLICA_ROWS=$(run "SELECT count() FROM system.replicas WHERE table='t_local'" | tr -d '[:space:]')

if [ "$DIST_COUNT" = "1000" ] && [ "$REPLICA_ROWS" -gt 0 ] 2>/dev/null; then
  echo "==> data path OK (distributed count=1000, replicas registered=$REPLICA_ROWS)"
else
  echo "==> SMOKE TEST FAILED (distributed count=$DIST_COUNT expected 1000; replicas=$REPLICA_ROWS expected >0)" >&2
  exit 1
fi

# Optional topology assertion. system.clusters holds ONE ROW PER HOST, i.e. one row for
# every (shard, replica) pair, so the expected count is shards x replicas -- not
# replicas. Without this a template rendered with the wrong shardsCount/replicasCount
# still passes every check above, because 1000 rows land wherever the cluster says.
if [ -n "${EXPECTED_REPLICAS:-}" ]; then
  EXPECTED_SHARDS=${EXPECTED_SHARDS:-1}
  EXPECTED_HOSTS=$((EXPECTED_SHARDS * EXPECTED_REPLICAS))
  ACTUAL=$(run "SELECT count() FROM system.clusters WHERE cluster='$LOGICAL_CLUSTER'" | tr -d '[:space:]')
  if [ "$ACTUAL" != "$EXPECTED_HOSTS" ]; then
    echo "==> SMOKE TEST FAILED (system.clusters has $ACTUAL host row(s) for '$LOGICAL_CLUSTER', expected $EXPECTED_HOSTS = ${EXPECTED_SHARDS} shard(s) x ${EXPECTED_REPLICAS} replica(s))" >&2
    exit 1
  fi
  echo "==> topology verified: $ACTUAL host row(s) = ${EXPECTED_SHARDS}x${EXPECTED_REPLICAS}"
fi

echo "==> SMOKE TEST PASSED ($NS/$CHI)"
