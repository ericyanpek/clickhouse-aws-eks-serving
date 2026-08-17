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

# Topology is asserted FIRST and unconditionally.
#
# It has to come before any writes: with an incomplete cluster the inserts below still
# succeed -- 1000 rows land wherever the cluster currently claims to be -- so every
# later check passes and a half-configured cluster ships as healthy.
#
# The expected numbers come from the CHI itself rather than the caller. An env var the
# caller may omit turns the strongest check in this script into a no-op precisely when
# someone forgets to pass it, and a caller echoing back its own rendered value cannot
# catch a template that rendered the wrong topology in the first place.
#
# system.clusters holds ONE ROW PER HOST, i.e. one per (shard, replica) pair, so the
# expected count is shards x replicas.
EXPECTED_SHARDS=$(kubectl -n "$NS" get chi "$CHI" -o jsonpath='{.spec.configuration.clusters[0].layout.shardsCount}' 2>/dev/null)
EXPECTED_REPLICAS=$(kubectl -n "$NS" get chi "$CHI" -o jsonpath='{.spec.configuration.clusters[0].layout.replicasCount}' 2>/dev/null)
if ! [ "${EXPECTED_SHARDS:-}" -ge 1 ] 2>/dev/null || ! [ "${EXPECTED_REPLICAS:-}" -ge 1 ] 2>/dev/null; then
  echo "ERROR: could not read shardsCount/replicasCount from CHI '$CHI' in $NS." >&2
  echo "       Refusing to run: without the declared topology this test cannot tell a" >&2
  echo "       complete cluster from a half-configured one." >&2
  exit 1
fi
EXPECTED_HOSTS=$((EXPECTED_SHARDS * EXPECTED_REPLICAS))

echo "==> cluster topology (CHI declares ${EXPECTED_SHARDS}x${EXPECTED_REPLICAS} = $EXPECTED_HOSTS host(s))"
run "SELECT cluster, shard_num, replica_num, host_name FROM system.clusters WHERE cluster='$LOGICAL_CLUSTER' ORDER BY shard_num, replica_num"

ACTUAL_HOSTS=$(run "SELECT count() FROM system.clusters WHERE cluster='$LOGICAL_CLUSTER'" | tr -d '[:space:]')
if [ "$ACTUAL_HOSTS" != "$EXPECTED_HOSTS" ]; then
  echo "==> SMOKE TEST FAILED (system.clusters has $ACTUAL_HOSTS host row(s) for '$LOGICAL_CLUSTER', expected $EXPECTED_HOSTS)" >&2
  echo "    A count below the expected value usually means remote_servers has not been" >&2
  echo "    distributed to every replica yet, so the cluster is incomplete rather than" >&2
  echo "    misconfigured. deploy.sh waits for the CHI to report Completed to avoid this." >&2
  exit 1
fi
echo "==> topology verified: $ACTUAL_HOSTS host row(s) = ${EXPECTED_SHARDS}x${EXPECTED_REPLICAS}"

echo "==> create replicated + distributed tables"
run "CREATE TABLE IF NOT EXISTS default.t_local ON CLUSTER $LOGICAL_CLUSTER (id UInt64, v String)
     ENGINE=ReplicatedMergeTree('/clickhouse/tables/{shard}/t_local','{replica}') ORDER BY id"
run "CREATE TABLE IF NOT EXISTS default.t_dist ON CLUSTER $LOGICAL_CLUSTER AS default.t_local
     ENGINE=Distributed($LOGICAL_CLUSTER, default, t_local, rand())"

EXPECTED_ROWS=1000
echo "==> insert via distributed table ($EXPECTED_ROWS rows)"
run "INSERT INTO default.t_dist SELECT number, toString(number) FROM numbers($EXPECTED_ROWS)"

# Replication is only observable with a second replica of the same shard.
#
# The pod name is chi-<chi>-<cluster>-<shard>-<replica>-<ordinal>, and the trailing
# ordinal is easy to forget: "chi-ebs-main-0-1" looks right but matches nothing, so the
# `get pod` below fails, the check is skipped, and the run still reports PASSED. That is
# exactly what happened until 2026-08-17 -- the cross-replica check never once executed.
# Selecting by label instead of constructing the name avoids re-deriving the convention.
PEER=$(kubectl -n "$NS" get pods -l "clickhouse.altinity.com/chi=$CHI" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null |
  grep -E "^chi-$CHI-$LOGICAL_CLUSTER-0-1-[0-9]+$" | head -1)
if [ -n "$PEER" ]; then
  echo "==> verify replication (query the OTHER replica of shard 0: $PEER)"
  # The result must be ASSERTED, not just printed. Reading 0 rows here means
  # replication is broken, yet the run used to continue and pass: the distributed
  # count below is served by the replica that already has the data.
  #
  # Replication is asynchronous, so poll rather than reading once.
  PEER_ROWS=0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    PEER_ROWS=$(run_on "$PEER" "SELECT count() FROM default.t_local" | tr -d '[:space:]')
    [ "${PEER_ROWS:-0}" = "$EXPECTED_ROWS" ] && break
    sleep 3
  done
  if [ "${PEER_ROWS:-0}" != "$EXPECTED_ROWS" ]; then
    echo "==> SMOKE TEST FAILED (replica $PEER has ${PEER_ROWS:-0} row(s), expected $EXPECTED_ROWS)" >&2
    echo "    The write reached one replica but did not replicate within 30s." >&2
    exit 1
  fi
  echo "==> replication verified: $PEER has $PEER_ROWS row(s)"
else
  echo "==> single replica per shard 0 (no ...-0-1-N pod); skipping cross-replica check"
fi

# Total across all shards must still be 1000: with 1 shard the Distributed table is a
# single-hop passthrough, with N shards it fans out and sums the parts.
echo "==> total via distributed table"
DIST_COUNT=$(run "SELECT count() FROM default.t_dist" | tr -d '[:space:]')
echo "distributed count = $DIST_COUNT"

echo "==> replication health"
run "SELECT database, table, is_readonly, absolute_delay FROM system.replicas WHERE table='t_local'"
REPLICA_ROWS=$(run "SELECT count() FROM system.replicas WHERE table='t_local'" | tr -d '[:space:]')

if [ "$DIST_COUNT" = "$EXPECTED_ROWS" ] && [ "${REPLICA_ROWS:-0}" -gt 0 ] 2>/dev/null; then
  echo "==> data path OK (distributed count=$DIST_COUNT, replicas registered=$REPLICA_ROWS)"
else
  echo "==> SMOKE TEST FAILED (distributed count=$DIST_COUNT expected $EXPECTED_ROWS; replicas=$REPLICA_ROWS expected >0)" >&2
  exit 1
fi

echo "==> SMOKE TEST PASSED ($NS/$CHI)"
