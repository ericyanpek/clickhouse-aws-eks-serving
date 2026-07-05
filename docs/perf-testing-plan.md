# ClickHouse Performance & Stress Testing Plan
### 1 Shard × 3 Replicas on EKS (i8g.4xlarge / ARM Graviton / Local NVMe)

**Cluster:** Altinity Operator 0.27.1 · ReplicatedMergeTree · 3× ClickHouse pods on dedicated i8g.4xlarge nodes · 3× Keeper on gp3 nodes  
**Access:** ClusterIP only — all load driven from an in-cluster Job pod or `kubectl port-forward`  
**Goal:** Find the single-node query ceiling, validate that reads scale ~linearly across 3 replicas, stress insert/merge throughput, and prove HA resilience under chaos.

---

## Part A — Authoritative Benchmark Datasets

### Dataset Quick Reference

| # | Dataset | Rows | Compressed Size | Schema Shape | Primary Stress | Best For This Cluster |
|---|---------|------|-----------------|--------------|----------------|-----------------------|
| 1 | **ClickBench `hits`** | 99.9M | ~14 GB (Parquet) / ~15 GB (CSV.gz) | 1 wide flat table, 105 columns | Full-column scans, filtered aggregation, regex, ORDER BY | **Primary benchmark** — single-node ceiling & parallel_replicas |
| 2 | **SSB (Star Schema Benchmark)** | SF100 = 600M rows (lineorder) | ~355 GB uncompressed at SF2500 | Star schema: 1 fact + 4 dim tables; denormalized flat variant | Multi-table JOINs, aggregation, GROUP BY with filters | JOIN overhead, denormalized vs. star query comparison |
| 3 | **TPC-H** | SF100 = 600M rows (lineitem) | ~100 GB at SF100 | 8 normalized tables, snowflake-adjacent | Complex subqueries, multi-way JOINs, sort-heavy | Limited fit — CK is not a join-optimized OLTP engine; use for completeness only |
| 4 | **TPC-DS** | SF200 = 1.4B rows (store_sales) | ~200+ GB at SF200 | 24-table snowflake, skewed distributions | 99 reporting/ad-hoc queries, complex SQL | Very limited — only ~8/99 queries complete on stock CK; skip unless SQL coverage is the goal |
| 5 | **NYC Taxi** | 3B+ trips (full); ~1.1B (historical 2009–2015) | ~227 GB uncompressed CSV (full) | 1 fact table, 30–50 columns, time-series | Time-range aggregation, GROUP BY, filtered scans | Insert throughput test; real-world messy data |
| 6 | **OnTime (airline)** | ~200M rows (1987–2022) | ~141 GB uncompressed | 1 wide table, 109 columns | Temporal aggregation, carrier/airport GROUP BY | Tutorial-scale warm-up; multi-year range scans |
| 7 | **GitHub Events** | 3.1B records (2011–2020) | ~75 GB download / ~200 GB on disk | 1 semi-structured wide table | Large-scale aggregation, string search, LIKE | Big-scale single-node ceiling validation; fits on 3.75 TB NVMe |

---

### A1 — ClickBench (`hits` dataset)

**What it is:** The canonical ClickHouse benchmark, created in October 2013 from 1/50th of one week of Yandex Metrica production pageviews. It contains ~99,997,497 rows and 105 columns of real web-analytics data (anonymized). The query set (43 queries) covers full-table scans, filtered aggregation, regex search in URL strings, ORDER BY with LIMIT, and multi-column GROUP BY. It is the standard reference used on [benchmark.clickhouse.com](https://benchmark.clickhouse.com/) and [benchmark.clickhouse.com/hardware/](https://benchmark.clickhouse.com/hardware/).

**Source:** [https://github.com/ClickHouse/ClickBench](https://github.com/ClickHouse/ClickBench)  
**Dashboard:** [https://benchmark.clickhouse.com/](https://benchmark.clickhouse.com/)

**Download URLs (verified from the ClickBench GitHub README):**

| Format | URL |
|--------|-----|
| **CSV.gz** | `https://datasets.clickhouse.com/hits_compatible/hits.csv.gz` (~15 GB compressed, ~75 GB uncompressed) |
| **TSV.gz** | `https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz` |
| **JSONlines.gz** | `https://datasets.clickhouse.com/hits_compatible/hits.json.gz` |
| **Parquet** | `https://datasets.clickhouse.com/hits_compatible/hits.parquet` (~14 GB, internally compressed) |
| **Parquet (100 partitioned files)** | `https://datasets.clickhouse.com/hits_compatible/athena_partitioned/hits_{0..99}.parquet` |

**Schema:** Official DDL at `https://github.com/ClickHouse/ClickBench/blob/main/clickhouse/create.sql`  
**Queries:** Official 43-query file at `https://github.com/ClickHouse/ClickBench/blob/main/clickhouse/queries.sql`

**On-disk size after ClickHouse ingestion:** ~14.21 GiB (ClickHouse native columnar compression with LZ4). Source: [ClickHouse OLAP ranking page, May 2026](https://clickhouse.com/resources/engineering/fastest-olap-databases).

**Relevance to this cluster:**
- PRIMARY benchmark for finding the single-node query ceiling (queries Q3, Q6, Q12, Q14, Q33–Q43 are the CPU/scan-heavy ones that saturate 16 vCPUs).
- 14 GB fits trivially on the 3.75 TB NVMe — load once, test repeatedly.
- Directly supports the `parallel_replicas` ON vs. OFF comparison (step C2 below).

---

### A2 — Star Schema Benchmark (SSB)

**What it is:** An OLAP benchmark from O'Neil et al. (2009), derived from TPC-H but restructured into a proper star schema. The fact table (`lineorder`) is surrounded by four dimension tables (`customer`, `supplier`, `part`, `date`). 13 queries across 4 "flights" test JOIN + GROUP BY + filter combinations. ClickHouse docs also cover a **denormalized flat variant** (`lineorder_flat`) that eliminates JOINs and turns SSB into a single-wide-table scan — a fair test of CK's columnar aggregation.

**Scale factors:** `-s 1` ≈ 6M rows; `-s 100` ≈ 600M rows (lineorder); `-s 2500` ≈ 15B rows (used by Altinity and Percona in published tests).

**Data generator:**
```bash
git clone https://github.com/vadimtk/ssb-dbgen.git
cd ssb-dbgen && make
./dbgen -s 100 -T c   # customer
./dbgen -s 100 -T l   # lineorder
./dbgen -s 100 -T p   # part
./dbgen -s 100 -T s   # supplier
./dbgen -s 100 -T d   # date
```
Source: [ClickHouse Docs — Star Schema Benchmark](https://clickhouse.com/docs/getting-started/example-datasets/star-schema)

**Note on date format:** The stock dbgen emits dates as `19971125`; ClickHouse requires `1997-11-25`. The Altinity fork at `https://github.com/vadimtk/ssb-dbgen` includes this fix. Source: [Altinity blog, 2017](https://altinity.com/blog/2017-6-16-clickhouse-in-a-general-analytical-workload-based-on-star-schema-benchmark).

**Relevance to this cluster:** SF100 (600M rows, ~60 GB raw) fits well on NVMe. The flat-table variant is directly comparable to ClickBench's scan pattern. The star-schema variant tests JOIN performance — a secondary concern for a CK OLAP serving layer but useful for characterizing query plans.

---

### A3 — TPC-H

**What it is:** The Transaction Processing Performance Council's decision-support benchmark (1999). 8 tables, 22 queries with complex multi-way JOINs, subqueries, aggregations. SF100 generates ~600M rows in `lineitem` (the main fact table), producing ~100 GB total raw data.

**Generator:**
```bash
git clone https://github.com/gregrahn/tpch-kit.git
cd tpch-kit/dbgen && make
./dbgen -s 100      # SF100 = ~100 GB
```
Source: [ClickHouse Docs — TPC-H](https://clickhouse.com/docs/getting-started/example-datasets/tpch)

**ClickHouse also provides pre-staged SF1 data via S3** (see the ClickHouse docs for `INSERT INTO nation SELECT * FROM s3('...', NOSIGN, CSV)` syntax).

**Honest assessment:** ClickHouse is not optimized for TPC-H-style multi-join snowflake queries. In a published head-to-head (Exasol vs. ClickHouse, Oct 2025), CK's median TPC-H runtime was 2,546 ms vs. Exasol's 238 ms across 22 queries. The gap is widest on queries with deep multi-way JOINs (Q17, Q21). Use TPC-H in this plan only to characterize JOIN performance limits — not as a primary benchmark.

---

### A4 — TPC-DS

**What it is:** 24-table snowflake schema, 99 queries, skewed distributions (Poisson/normal). Valid scale factors: 100, 300, 1000, 3000+ GB. Source: [ClickHouse Docs — TPC-DS](https://clickhouse.com/docs/getting-started/example-datasets/tpcds)

**Honest assessment:** In an independent benchmark (Radiant Advisors, 2024), only 8 of 99 TPC-DS queries completed on ClickHouse at SF200. **Skip TPC-DS for this plan** unless SQL compatibility is under test. It is included here for completeness.

---

### A5 — NYC Taxi Dataset

**What it is:** New York City TLC taxi trip records. Two common scales:
- **Sample (3M rows):** S3 URLs `https://datasets-documentation.s3.eu-west-3.amazonaws.com/nyc-taxi/trips_{0..2}.gz`
- **Full prepared partitions:** `https://datasets.clickhouse.com/trips_mergetree/partitions/trips_mergetree.tar` (~227 GB uncompressed, 3B+ rows including FHV/Uber/Lyft through 2024)
- **Historical 1.1B rows (2009–2015):** Mark Litwintschik's 56-file dataset at `s3://nyc-tlc/trip data/` (GZIP CSV, 104 GB compressed, 500 GB decompressed). Source: [tech.marksblogg.com](https://tech.marksblogg.com/billion-taxi-rides-doublecloud-clickhouse.html)

Source for ClickHouse loading instructions: [ClickHouse Docs — NYC Taxi](https://clickhouse.com/docs/getting-started/example-datasets/nyc-taxi)

**Relevance:** The 1.1B-row historical dataset (500 GB uncompressed, ~144 GB in ClickHouse MergeTree) is the best dataset for **insert throughput stress testing** — it is large enough to saturate the insert pipeline and trigger significant merge activity. It fits on the 3.75 TB NVMe with headroom.

---

### A6 — OnTime (Airline On-Time Performance)

**What it is:** Bureau of Transportation Statistics flight data, 1987–2022. ~200M rows, 109 columns. Source: [ClickHouse Docs — OnTime](https://clickhouse.com/docs/getting-started/example-datasets/ontime)

**Load from ClickHouse's S3 snapshot:**
```sql
INSERT INTO ontime SELECT * FROM s3(
  'https://clickhouse-public-datasets.s3.amazonaws.com/ontime/csv_by_year/*.csv.gz',
  CSVWithNames
) SETTINGS max_insert_threads = 16;
```

**Relevance:** Good warm-up / smoke-test dataset. 200M rows ingests quickly (~30 min on NVMe), and the temporal query set (year/month/carrier aggregations) is representative of BI serving queries.

---

### A7 — GitHub Events (Large-Scale Validation)

**What it is:** All GitHub events from 2011 to December 6, 2020. 3.1 billion records, 75 GB download, ~200 GB on-disk with LZ4 compression. Source: [ClickHouse Docs — GitHub Events](https://clickhouse.com/docs/getting-started/example-datasets/github-events) and [GitHub repository](https://github.com/ClickHouse/github-explorer).

**Relevance:** At 200 GB compressed, this dataset fits on the 3.75 TB NVMe and provides a realistic "big-scale" single-node ceiling test without requiring multi-file orchestration. Excellent for validating that scans at 3B+ rows remain sub-second with proper indexing, and for stress-testing memory under high-cardinality GROUP BY.

---

### Dataset Selection Summary for This Plan

| Test Goal | Recommended Dataset |
|-----------|---------------------|
| Single-node query ceiling (scan speed) | ClickBench `hits` (100M rows, 14 GB) |
| `parallel_replicas` ON vs. OFF speedup | ClickBench `hits` — identical queries |
| Read concurrency / QPS ramp | ClickBench `hits` (warm cache) |
| Insert / merge throughput stress | NYC Taxi 1.1B rows OR GitHub Events |
| JOIN performance characterization | SSB SF100 flat + star variants |
| Large-scale single-node validation | GitHub Events (3.1B rows) |

---

## Part B — Tooling

### B1 — `clickhouse-benchmark` (built-in load generator)

The tool ships with `clickhouse-client` and is the standard mechanism for concurrency + QPS + latency-percentile benchmarking.

**Key flags** (from [ClickHouse Docs](https://clickhouse.com/docs/operations/utilities/clickhouse-benchmark)):

| Flag | Default | Purpose |
|------|---------|---------|
| `-c / --concurrency=N` | 1 | Simultaneous query threads (the primary "load" knob) |
| `-C / --max_concurrency=N` | — | Ramp from 1 up to N (graduated load sweep) |
| `-i / --iterations=N` | 0 (infinite) | Total queries to send |
| `-t / --timelimit=N` | 0 | Stop after N seconds |
| `-r / --randomize` | off | Pick queries randomly from file (prevents caching effects on ordered queries) |
| `--delay=N` | 1 | Seconds between progress reports |
| `--cumulative` | off | Print cumulative vs. per-interval stats |
| `--continue_on_errors` | off | Do not abort on query error (needed for stress tests) |
| `--host=H --port=P` | localhost:9000 | Target; specify multiple pairs to compare two servers statistically |
| `--roundrobin` | off | Round-robin across `--host` entries per query (use to spread load across 3 replicas) |

**Output metrics per reporting interval:**
- `QPS` — queries per second
- `RPS` — rows read per second
- `MiB/s` — data read throughput
- Latency percentiles at 0%, 10%, 20%, …, 95%, 99%, 99.9%, 99.99%

**Comparison mode:** Specify `--host=A --port=9000 --host=B --port=9000` to run two servers in parallel and get a Student's t-test significance result at configurable confidence.

**Basic invocation:**
```bash
cat queries.sql | clickhouse-benchmark \
  --host=clickhouse-svc.clickhouse.svc.cluster.local \
  --port=9000 \
  --concurrency=8 \
  --iterations=200 \
  --randomize \
  --delay=5
```

### B2 — ClickBench Official Harness

The ClickBench repo (`https://github.com/ClickHouse/ClickBench`) contains a per-system `benchmark.sh` script. For ClickHouse the canonical single-run approach is:

```bash
# Run each of the 43 queries 3 times; report cold (run 1) and hot (min of run 2,3)
while read -r query; do
  clickhouse-client --query "$query" --format Null  # warm
  clickhouse-client --query "$query" --time --format Null 2>&1 | tail -1
  clickhouse-client --query "$query" --time --format Null 2>&1 | tail -1
done < queries.sql
```

The published leaderboard at `benchmark.clickhouse.com` uses a `c6a.4xlarge` as the reference machine; results on an `i8g.4xlarge` (Graviton, 16 vCPU / 128 GiB) should be comparable or faster on scan-heavy queries due to higher memory bandwidth in Neoverse V2 cores.

### B3 — System Tables for Metrics Capture

All queries run against the relevant ClickHouse pod directly.

**Per-query performance (after the fact):**
```sql
SELECT
    query_id,
    query,
    query_duration_ms,
    read_rows,
    read_bytes,
    memory_usage,
    peak_memory_usage,
    ProfileEvents['RealTimeMicroseconds'] / 1e6 AS wall_sec,
    ProfileEvents['UserTimeMicroseconds'] / 1e6 AS cpu_user_sec
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time > now() - INTERVAL 1 HOUR
ORDER BY query_duration_ms DESC
LIMIT 20;
```

**Merge backlog (insert stress):**
```sql
SELECT database, table, elapsed, progress, num_parts, source_part_names, result_part_name
FROM system.merges
ORDER BY elapsed DESC;
```

**Replication lag (HA/chaos test):**
```sql
SELECT
    database, table, replica_name,
    is_leader, is_readonly,
    absolute_delay,              -- seconds behind most-advanced replica
    queue_size, inserts_in_queue, merges_in_queue,
    active_replicas, total_replicas,
    log_max_index - log_pointer AS log_lag
FROM system.replicas
ORDER BY absolute_delay DESC;
```

**Replication event counters (running totals since server start):**
```sql
SELECT event, value FROM system.events
WHERE event IN ('ReplicatedPartFetches','ReplicatedPartFetchesOfMerged','ReplicatedDataLoss');
-- ReplicatedDataLoss must stay 0
```

**Live server memory:**
```sql
SELECT metric, value
FROM system.asynchronous_metrics
WHERE metric IN (
    'MemoryResident', 'MemoryVirtual',
    'jemalloc.resident', 'jemalloc.mapped'
);
```

**Current connections / query concurrency:**
```sql
SELECT metric, value FROM system.metrics
WHERE metric IN ('Query', 'Merge', 'ReplicatedFetch', 'Connection');
```

### B4 — Prometheus / Grafana

The Altinity operator exposes ClickHouse metrics to Prometheus automatically via the metrics-exporter sidecar. The official dashboard is:

- **Grafana dashboard ID 12163** — "Altinity ClickHouse Operator Dashboard"  
  URL: [https://grafana.com/grafana/dashboards/12163-altinity-clickhouse-operator-dashboard](https://grafana.com/grafana/dashboards/12163-altinity-clickhouse-operator-dashboard)

Import dashboard 12163 into your in-cluster Grafana (`kubectl port-forward svc/grafana 3000:3000 -n monitoring`). Key panels during tests:
- `ClickHouseMetrics_Query` — live concurrent query count
- `ClickHouseAsynchronousMetrics_MemoryResident` — RSS memory per pod
- `ClickHouseMetrics_ReplicatedFetch` — active replica fetch threads (spikes during HA recovery)
- CPU/network throughput from Kubernetes node metrics

### B5 — In-Cluster Load Driver: Kubernetes Job Spec

Since access is ClusterIP only, all `clickhouse-benchmark` invocations run as a Kubernetes Job inside the cluster. The service `clickhouse-svc` (ClusterIP) load-balances across all 3 pods.

```yaml
# perf-driver-job.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: clickbench-driver
  namespace: clickhouse
spec:
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: bench
        image: clickhouse/clickhouse-server:24.8-alpine   # matches cluster version
        command:
        - /bin/bash
        - -c
        - |
          set -euo pipefail
          # Download ClickBench queries
          wget -q -O /tmp/queries.sql \
            https://raw.githubusercontent.com/ClickHouse/ClickBench/main/clickhouse/queries.sql
          # Single-pass: each query once, capture timing
          echo "query_num,duration_ms" > /tmp/results.csv
          i=1
          while IFS= read -r query; do
            T=$(clickhouse-client \
              --host=clickhouse-svc.clickhouse.svc.cluster.local \
              --query="$query" --time --format Null 2>&1 | tail -1)
            echo "$i,$T"
            i=$((i+1))
          done < /tmp/queries.sql | tee -a /tmp/results.csv
          echo "=== Results ==="
          cat /tmp/results.csv
        resources:
          requests: { cpu: "2", memory: "4Gi" }
          limits:   { cpu: "4", memory: "8Gi" }
      nodeSelector:
        # Pin to a non-ClickHouse node (avoid co-location with CH pods)
        node-role: "general"
```

For `clickhouse-benchmark` concurrency sweeps, replace the command block with:

```bash
clickhouse-benchmark \
  --host=clickhouse-svc.clickhouse.svc.cluster.local \
  --port=9000 \
  --concurrency="${CONCURRENCY:-8}" \
  --timelimit=120 \
  --randomize \
  --delay=10 \
  --continue_on_errors \
  < /tmp/queries.sql
```

---

## Part C — Staged Test Plan

### Prerequisites

```bash
# Confirm cluster health before any test
kubectl -n clickhouse exec -it chi-clickhouse-0-0-0 -- \
  clickhouse-client --query "SELECT * FROM system.replicas \
    WHERE active_replicas < total_replicas FORMAT Vertical"
# Must return 0 rows (all replicas active)

kubectl -n clickhouse exec -it chi-clickhouse-0-0-0 -- \
  clickhouse-client --query "SELECT * FROM system.merges" | wc -l
# Should be low (< 5) before starting insert tests
```

---

### Stage 1 — Data Loading

**Dataset:** ClickBench `hits` (primary benchmark) + NYC Taxi 1.1B rows (insert stress)

**Step 1a — Create the `hits` table (ReplicatedMergeTree):**

```sql
-- Run on any one replica; Altinity operator propagates DDL via Keeper
CREATE DATABASE IF NOT EXISTS bench ON CLUSTER '{cluster}';

-- Adapted from https://github.com/ClickHouse/ClickBench/blob/main/clickhouse/create.sql
-- Replace MergeTree with ReplicatedMergeTree for this 1×3 cluster
CREATE TABLE bench.hits ON CLUSTER '{cluster}'
(
    WatchID         UInt64,
    JavaEnable      UInt8,
    Title           String,
    GoodEvent       Int16,
    EventTime       DateTime,
    EventDate       Date,
    CounterID       UInt32,
    ClientIP        UInt32,
    RegionID        UInt32,
    UserID          UInt64,
    -- ... (remaining 95 columns from the official DDL) ...
    -- Download full DDL:
    -- wget https://raw.githubusercontent.com/ClickHouse/ClickBench/main/clickhouse/create.sql
)
ENGINE = ReplicatedMergeTree(
    '/clickhouse/tables/{shard}/bench/hits',
    '{replica}'
)
PARTITION BY toYYYYMM(EventDate)
ORDER BY (CounterID, EventDate, intHash32(UserID))
SAMPLE BY intHash32(UserID)
SETTINGS index_granularity = 8192;
```

**Step 1b — Load hits from S3 (no local download needed):**

```sql
-- Load directly from ClickHouse's public S3 — no IAM credentials required
-- Insert goes to one replica; ReplicatedMergeTree replicates to the other two
INSERT INTO bench.hits
SELECT * FROM s3(
    'https://datasets.clickhouse.com/hits_compatible/hits.parquet',
    'Parquet'
)
SETTINGS
    max_insert_threads = 14,        -- match CPU request (14 vCPU)
    input_format_parquet_max_block_size = 65536;
```

Monitor replication during load:
```sql
-- Poll every 30s from a second pod to confirm replication is keeping up
SELECT replica_name, absolute_delay, queue_size, inserts_in_queue
FROM system.replicas WHERE table = 'hits';
```

**Expected:** Load completes in 5–10 min from S3 to one replica; all 3 replicas synchronized within 15 min. On-disk size per replica: ~14 GiB. Total NVMe used: 42 GiB across the cluster (14 GiB × 3).

**Step 1c — Validate row count:**
```sql
SELECT count() FROM bench.hits;
-- Expected: 99,997,497
```

**Step 1d — Load NYC Taxi 1.1B rows (for insert stress test — Stage 4):**

```sql
CREATE TABLE bench.trips ON CLUSTER '{cluster}'
(
    trip_id         UInt32,
    pickup_date     Date,
    pickup_datetime DateTime,
    dropoff_datetime DateTime,
    pickup_longitude  Float64,
    pickup_latitude   Float64,
    dropoff_longitude Float64,
    dropoff_latitude  Float64,
    passenger_count UInt8,
    trip_distance   Float64,
    tip_amount      Float32,
    total_amount    Float32,
    payment_type    Enum8('UNK'=0,'CSH'=1,'CRE'=2,'NOC'=3,'DIS'=4)
)
ENGINE = ReplicatedMergeTree(
    '/clickhouse/tables/{shard}/bench/trips',
    '{replica}'
)
PARTITION BY toYYYYMM(pickup_date)
ORDER BY pickup_datetime;

-- Load prepared partitions from ClickHouse public S3
-- Full dataset: https://datasets.clickhouse.com/trips_mergetree/partitions/trips_mergetree.tar
-- Or load the 3-file sample first as a smoke test:
INSERT INTO bench.trips
SELECT * FROM s3(
    'https://datasets-documentation.s3.eu-west-3.amazonaws.com/nyc-taxi/trips_{0..2}.gz',
    'TabSeparatedWithNames'
)
SETTINGS max_insert_threads = 14;
```

**NVMe sizing check:** ClickHouse compresses taxi data to roughly 1 byte/row. 1.1B rows ≈ ~144 GB per replica × 3 replicas = ~432 GB total NVMe. Well within 3.75 TB per node.

---

### Stage 2 — Performance Test: Single-Query Ceiling

**Goal:** Run the full ClickBench 43-query suite; identify the scan-heavy queries that saturate one node's 16 vCPUs (the "scale-up wall"); then test `parallel_replicas` ON vs. OFF on those queries.

**Step 2a — Baseline: 43 queries, single replica, no parallel_replicas:**

Deploy the in-cluster Job:
```yaml
# Override the command in perf-driver-job.yaml with:
command:
- /bin/bash
- -c
- |
  wget -q -O /tmp/queries.sql \
    https://raw.githubusercontent.com/ClickHouse/ClickBench/main/clickhouse/queries.sql

  echo "run,query_num,cold_ms,hot1_ms,hot2_ms" > /results/clickbench_single_replica.csv
  i=1
  while IFS= read -r query; do
    # Cold run (drop mark cache before first run)
    clickhouse-client \
      --host=chi-clickhouse-0-0-0.clickhouse-headless.clickhouse.svc.cluster.local \
      --query="SYSTEM DROP MARK CACHE; SYSTEM DROP UNCOMPRESSED CACHE"
    COLD=$(clickhouse-client \
      --host=chi-clickhouse-0-0-0.clickhouse-headless.clickhouse.svc.cluster.local \
      --query="$query" --time --format Null 2>&1 | tail -1)
    HOT1=$(clickhouse-client \
      --host=chi-clickhouse-0-0-0.clickhouse-headless.clickhouse.svc.cluster.local \
      --query="$query" --time --format Null 2>&1 | tail -1)
    HOT2=$(clickhouse-client \
      --host=chi-clickhouse-0-0-0.clickhouse-headless.clickhouse.svc.cluster.local \
      --query="$query" --time --format Null 2>&1 | tail -1)
    echo "1,$i,$COLD,$HOT1,$HOT2"
    i=$((i+1))
  done < /tmp/queries.sql | tee -a /results/clickbench_single_replica.csv
```

Note: Direct pod address (`chi-clickhouse-0-0-0.clickhouse-headless.…`) bypasses the ClusterIP LB and pins queries to one replica. The Altinity operator creates a headless service for pod-level addressing.

**Step 2b — Identify the "scale-up wall" queries:**

Queries that typically saturate CPU on a 16-vCPU node (based on published ClickBench results):
- **Q6** — `count()` on a full-table scan (storage throughput bound)
- **Q12, Q14** — `uniq()` on UserID (high-cardinality, memory bandwidth)
- **Q33–Q43** — complex multi-column aggregations, regex in URL columns

Capture from `system.query_log` after the run:
```sql
SELECT
    query_id, left(query, 80) AS query_prefix,
    query_duration_ms,
    read_rows, formatReadableSize(read_bytes) AS data_read,
    formatReadableSize(peak_memory_usage) AS peak_mem,
    ProfileEvents['RealTimeMicroseconds'] / ProfileEvents['UserTimeMicroseconds'] AS cpu_efficiency
FROM system.query_log
WHERE type = 'QueryFinish'
  AND tables LIKE '%hits%'
  AND event_time > now() - INTERVAL 2 HOUR
ORDER BY query_duration_ms DESC
LIMIT 10;
```

**Pass criterion:** All 43 queries complete without OOM. Queries with `query_duration_ms > 5000` are candidates for `parallel_replicas` optimization.

**Step 2c — `parallel_replicas` ON vs. OFF comparison:**

Re-run the top-5 slowest queries with `parallel_replicas` enabled. This is the key validation of the 1×3 topology's "virtual sharding" capability.

```sql
-- OFF (baseline, already measured)
SELECT <heavy_query_from_step_2b>;

-- ON: distribute across all 3 replicas
SELECT <heavy_query_from_step_2b>
SETTINGS
    enable_parallel_replicas = 1,
    max_parallel_replicas = 3,
    cluster_for_parallel_replicas = 'clickhouse',   -- your CHI cluster name
    enable_analyzer = 1,                             -- required
    parallel_replicas_min_number_of_rows_per_replica = 10000000;
```

Source: [ClickHouse Docs — Parallel Replicas](https://clickhouse.com/docs/deployment-guides/parallel-replicas)

**Pass criterion:** `parallel_replicas = 3` reduces wall-clock time by ≥ 2× on scan-heavy queries (theoretical max: 3×, practical: 2–2.5× accounting for coordination overhead). This demonstrates the design philosophy's claim that `parallel_replicas` defers the need for true sharding.

**Expected reference:** On a ClickHouse Cloud blog post ([clickhouse.com/blog/clickhouse-parallel-replicas](https://clickhouse.com/blog/clickhouse-parallel-replicas)), a 30M-row GROUP BY completed in 33 ms on one node; with 3 parallel replicas on comparable hardware, sub-15 ms was observed. Your 16-vCPU/128 GiB Graviton nodes are well-matched for this test.

---

### Stage 3 — Read Concurrency / QPS Ramp

**Goal:** Ramp `--concurrency` from 1 to 64 via `clickhouse-benchmark` hitting the **ClusterIP service** (which round-robins across all 3 replicas). Plot QPS + p50/p95/p99 latency. Find the "knee" where latency inflects.

**Step 3a — Concurrency sweep Job:**

```yaml
# concurrency-sweep-job.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: concurrency-sweep
  namespace: clickhouse
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: sweep
        image: clickhouse/clickhouse-server:24.8-alpine
        command:
        - /bin/bash
        - -c
        - |
          wget -q -O /tmp/queries.sql \
            https://raw.githubusercontent.com/ClickHouse/ClickBench/main/clickhouse/queries.sql

          # Use only the 10 most scan-heavy queries (Q6,Q12,Q14,Q33-Q43)
          # to stress CPU, not just fast-returning queries
          head -n 20 /tmp/queries.sql > /tmp/heavy_queries.sql

          for CONC in 1 2 4 8 16 32 64; do
            echo "=== CONCURRENCY=$CONC ==="
            clickhouse-benchmark \
              --host=clickhouse-svc.clickhouse.svc.cluster.local \
              --port=9000 \
              --concurrency=$CONC \
              --timelimit=120 \
              --randomize \
              --delay=30 \
              --continue_on_errors \
              --cumulative \
              < /tmp/heavy_queries.sql \
              2>&1 | tee /tmp/concurrency_${CONC}.log
            sleep 30   # let merges settle between levels
          done
        resources:
          requests: { cpu: "4", memory: "8Gi" }
          limits: { cpu: "8", memory: "16Gi" }
```

**Step 3b — Extract summary metrics from logs:**
```bash
# Parse QPS from each log
for f in /tmp/concurrency_*.log; do
  CONC=$(echo $f | grep -o '[0-9]*\.log' | tr -d '.log')
  QPS=$(grep 'QPS:' $f | tail -1 | awk -F'QPS: ' '{print $2}' | awk '{print $1}')
  P99=$(grep '99.000%' $f | tail -1 | awk '{print $2}')
  echo "concurrency=$CONC qps=$QPS p99=$P99"
done
```

**Step 3c — Observe read distribution across replicas:**

While the sweep is running, from any pod:
```sql
-- Confirms queries are spread across all 3 replicas
SELECT hostname(), count() AS queries_handled
FROM clusterAllReplicas('{cluster}', system.query_log)
WHERE type = 'QueryFinish'
  AND event_time > now() - INTERVAL 5 MINUTE
GROUP BY hostname()
ORDER BY hostname();
```

**Pass criteria:**
- At concurrency=3 (one query per replica), QPS should be ≥ 3× the concurrency=1 baseline — confirming ~linear read scaling.
- p99 latency at concurrency=8 should be ≤ 3× the concurrency=1 p50 (acceptable degradation).
- The "knee" (where p99 starts growing superlinearly) should occur around concurrency = 3 × `max_threads_per_query` (roughly 48 for a 16-vCPU node, 3 replicas).

**Scaling knobs to vary during this stage:**
```sql
-- Load balancing strategy (try 'nearest_hostname' if round-robin causes hot-spots)
-- Set in users.xml or per-session:
SET load_balancing = 'random';          -- default; even distribution
SET load_balancing = 'nearest_hostname'; -- prefer same-AZ replica
SET load_balancing = 'round_robin';     -- strict round-robin

-- Per-query thread count (controls single-query parallelism within one node)
SET max_threads = 16;    -- default: use all vCPUs (matches CPU request = 14)
SET max_threads = 8;     -- halve to allow more concurrent queries
```

---

### Stage 4 — Insert / Merge Throughput Stress

**Goal:** Drive sustained high-rate inserts into the 3-replica cluster; measure write amplification (3× network traffic), merge backlog accumulation, and replication lag. Find the insert ceiling before `absolute_delay` exceeds the alert threshold.

**Step 4a — Sustained insert job (NYC Taxi 1.1B rows):**

```yaml
# insert-stress-job.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: insert-stress
  namespace: clickhouse
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: inserter
        image: clickhouse/clickhouse-server:24.8-alpine
        command:
        - /bin/bash
        - -c
        - |
          # Stream inserts from S3 in large batches
          # Each INSERT block = 1M rows (respects max_insert_block_size)
          clickhouse-client \
            --host=clickhouse-svc.clickhouse.svc.cluster.local \
            --port=9000 \
            --query="
              INSERT INTO bench.trips
              SELECT * FROM s3(
                'https://datasets-documentation.s3.eu-west-3.amazonaws.com/nyc-taxi/trips_{0..2}.gz',
                'TabSeparatedWithNames'
              )
              SETTINGS max_insert_threads = 8"
        resources:
          requests: { cpu: "2", memory: "4Gi" }
```

**Step 4b — Monitor during inserts (poll every 10s from a second terminal):**

```sql
-- Merge backlog
SELECT
    database, table,
    count() AS active_merges,
    sum(rows_read) AS total_rows_in_merges,
    max(elapsed) AS max_merge_age_sec
FROM system.merges
GROUP BY database, table;

-- Replication lag across all 3 nodes
SELECT
    hostname() AS node,
    database, table,
    absolute_delay, queue_size, inserts_in_queue, merges_in_queue
FROM clusterAllReplicas('{cluster}', system.replicas)
WHERE table = 'trips'
ORDER BY node, absolute_delay DESC;

-- Insert throughput (from query_log)
SELECT
    toStartOfMinute(event_time) AS minute,
    sum(written_rows) AS rows_written,
    formatReadableSize(sum(written_bytes)) AS bytes_written
FROM system.query_log
WHERE type = 'QueryFinish'
  AND query LIKE 'INSERT%'
  AND event_time > now() - INTERVAL 10 MINUTE
GROUP BY minute
ORDER BY minute;
```

**Step 4c — Find the insert ceiling:**

Gradually increase `--parallel` insert jobs (1, 2, 4 concurrent insert streams) and watch for:
```sql
-- Warning sign: too many parts (merge can't keep up)
SELECT count() AS part_count FROM system.parts WHERE table = 'trips' AND active;
-- ALERT if > 300 active parts per partition
```

When `inserts_in_queue` on any replica exceeds 100 and `absolute_delay` exceeds 60 seconds, you have found the insert ceiling.

**Bandwidth throttle knob** (from the project's best-practices notes):
```xml
<!-- In config.d/replica-fetch-throttle.xml — limits replica fetch to leave bandwidth for queries -->
<max_replicated_fetches_network_bandwidth_for_server>
  500000000  <!-- 500 MB/s; tune down to 100 MB/s during sustained inserts -->
</max_replicated_fetches_network_bandwidth_for_server>
```

**Pass criteria:**
- Insert rate ≥ 500K rows/sec sustained (single stream into 1 replica)
- `absolute_delay` on any replica stays < 60 s during single-stream inserts
- `ReplicatedDataLoss` counter = 0 throughout
- Merge queue drains after inserts stop within 5 minutes

---

### Stage 5 — HA / Resilience (Chaos Test)

**Goal:** Delete one replica pod under read load; confirm QPS degrades ~1/3 but service continues with no errors; measure recovery time after pod restores.

**Step 5a — Establish read baseline:**

Start a background concurrency sweep (concurrency=4) against the ClusterIP service:
```bash
# In terminal 1: run from in-cluster pod
clickhouse-benchmark \
  --host=clickhouse-svc.clickhouse.svc.cluster.local \
  --port=9000 \
  --concurrency=4 \
  --timelimit=300 \
  --randomize \
  --delay=5 \
  --continue_on_errors \
  < /tmp/queries.sql &
```

Record baseline QPS and p99.

**Step 5b — Kill one replica:**
```bash
# In terminal 2 (external / kubectl)
# Record which pod is being killed
kubectl -n clickhouse delete pod chi-clickhouse-0-0-2

# Kubernetes will reschedule the pod; the operator restores it
# The 2 remaining replicas continue serving queries
```

**Step 5c — Observe the degradation and recovery:**

Expected behavior:
1. ClusterIP service removes the deleted pod's endpoint (Kubernetes readiness probe → endpoint controller). Queries to the dead pod time out / fail; `--continue_on_errors` keeps the benchmark running.
2. Within 30–60 seconds, the load balancer drops the dead endpoint. QPS drops ~1/3 (from 3 active replicas to 2).
3. The pod restarts; the ClickHouse process comes up and registers with Keeper.
4. Keeper detects missing parts; the recovering replica fetches parts from the surviving replicas (the "replica fetch" fast path — copies already-merged parts, not individual INSERT blocks).

Monitor recovery:
```sql
-- Poll from a surviving replica
SELECT
    replica_name,
    is_readonly,
    absolute_delay,
    queue_size,
    inserts_in_queue,
    merges_in_queue,
    active_replicas
FROM system.replicas
WHERE table = 'hits';
-- absolute_delay should drop to < 10 within the recovery window
```

Prometheus metric during recovery:
```
ClickHouseMetrics_ReplicatedFetch > 0  -- indicates active part fetching
```

**Step 5d — HA with insert quorum (optional — validates write durability):**
```sql
-- This setting requires write acknowledgment from ≥ 2 replicas
-- before INSERT returns. Demonstrates that 1-replica failure doesn't lose data.
SET insert_quorum = 2;
SET insert_quorum_parallel = 0;
INSERT INTO bench.hits SELECT * FROM system.numbers LIMIT 100000;
```

**Pass criteria:**
- After pod deletion: QPS drops to ~2/3 of baseline within 60 s, not to 0
- Error rate in `clickhouse-benchmark` output: < 5% during the 30 s transition window
- `ReplicatedDataLoss` counter = 0 throughout
- After pod restart: `absolute_delay` returns to < 10 s within:
  - **5 min** if data size < 100 GB per replica (NVMe fast-path — copies MergeTree parts directly)
  - **20 min** if data size is 100–500 GB per replica
- `active_replicas` = 3 confirmed before ending the test

**Recovery bandwidth knob:** If recovery is competing with read load:
```xml
<max_replicated_fetches_network_bandwidth_for_server>
  200000000  <!-- 200 MB/s → recovers 100 GB in ~8 min while leaving ~800 MB/s for reads -->
</max_replicated_fetches_network_bandwidth_for_server>
```
Source: [best-practices notes §6](../docs/notes-ck-on-eks-best-practices-2026.md)

---

### Stage 6 — Metrics Collection and Pass/Fail Criteria Summary

| Stage | Key Metric | Pass Threshold | How to Measure |
|-------|-----------|----------------|----------------|
| 1 (Load) | Row count on all 3 replicas | = 99,997,497 | `SELECT count() FROM bench.hits` on each pod |
| 1 (Load) | Replication sync time | < 15 min after insert completes | `system.replicas.absolute_delay` = 0 |
| 2a (Single-query) | All 43 queries complete | No OOM, no timeout | `system.query_log WHERE type='QueryError'` = 0 |
| 2a (Single-query) | Median hot query time | < 1 s on 80% of queries | Per-query timing from benchmark script |
| 2c (parallel_replicas) | Speedup on heavy queries | ≥ 2× vs. single-replica baseline | Wall-clock comparison (query_duration_ms) |
| 3 (Read QPS) | QPS at concurrency=3 | ≥ 3× QPS at concurrency=1 | `clickhouse-benchmark` output |
| 3 (Read QPS) | p99 latency at concurrency=8 | ≤ 3× p50 at concurrency=1 | `clickhouse-benchmark` percentile output |
| 3 (Read QPS) | Query distribution | Queries spread across all 3 replicas ± 15% | `clusterAllReplicas` query_log count |
| 4 (Insert) | Sustained insert rate | ≥ 500K rows/sec | `system.query_log.written_rows` per minute |
| 4 (Insert) | Replication lag | `absolute_delay` < 60 s | `system.replicas` |
| 4 (Insert) | Data loss | `ReplicatedDataLoss` = 0 | `system.events` |
| 5 (HA) | Service continuity | QPS > 0, error rate < 5% during pod kill | `clickhouse-benchmark --continue_on_errors` |
| 5 (HA) | QPS degradation | QPS drops to ~2/3, not to 0 | `clickhouse-benchmark` interval reports |
| 5 (HA) | Recovery time | `absolute_delay` < 10 s within 20 min | `system.replicas` polling |

---

### Stage 7 — Scaling Knobs Reference

All settings should be tested in Part B (baseline) before activation. Change one at a time.

| Knob | Default | Test Value | Expected Effect | Stage |
|------|---------|------------|-----------------|-------|
| `enable_parallel_replicas` | 0 | 1 | Distribute single query across 3 replicas; 2–3× speedup on heavy scans | 2c |
| `max_parallel_replicas` | 1000 | 3 | Cap at 3 (match cluster size) | 2c |
| `cluster_for_parallel_replicas` | — | `'clickhouse'` (your CHI cluster name) | Required for parallel_replicas to work | 2c |
| `parallel_replicas_min_number_of_rows_per_replica` | 0 | 10,000,000 | Prevent parallel_replicas for tiny queries (avoids coordination overhead) | 2c |
| `enable_analyzer` | varies | 1 | Required for parallel_replicas; also enables modern query planner | 2c |
| `max_threads` | = vCPUs | 8 or 16 | Controls intra-query parallelism; reduce to leave headroom for concurrency | 3 |
| `load_balancing` | `random` | `round_robin` | Strict round-robin across replicas at the Distributed/client level | 3 |
| `max_replicated_fetches_network_bandwidth_for_server` | 0 (unlimited) | 200MB/s | Throttle replica recovery to protect read QPS | 4, 5 |
| `insert_quorum` | 0 | 2 | Require 2/3 replicas to acknowledge before INSERT returns; durability vs. latency trade-off | 4 optional |
| `max_insert_threads` | 1 | 14 | Parallelize S3→ClickHouse ingestion; fills all CPUs during bulk load | 1 |

---

## Appendix — Quick Reference

### Verified Source URLs

| Resource | Verified URL |
|----------|-------------|
| ClickBench GitHub | https://github.com/ClickHouse/ClickBench |
| ClickBench dashboard | https://benchmark.clickhouse.com/ |
| ClickBench hardware leaderboard | https://benchmark.clickhouse.com/hardware/ |
| hits.parquet | https://datasets.clickhouse.com/hits_compatible/hits.parquet |
| hits.csv.gz | https://datasets.clickhouse.com/hits_compatible/hits.csv.gz |
| hits.tsv.gz | https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz |
| hits partitioned (100 files) | https://datasets.clickhouse.com/hits_compatible/athena_partitioned/hits_{0..99}.parquet |
| ClickBench create.sql | https://github.com/ClickHouse/ClickBench/blob/main/clickhouse/create.sql |
| ClickBench queries.sql | https://github.com/ClickHouse/ClickBench/blob/main/clickhouse/queries.sql |
| SSB dbgen (Altinity fork) | https://github.com/vadimtk/ssb-dbgen |
| SSB ClickHouse docs | https://clickhouse.com/docs/getting-started/example-datasets/star-schema |
| TPC-H ClickHouse docs | https://clickhouse.com/docs/getting-started/example-datasets/tpch |
| TPC-DS ClickHouse docs | https://clickhouse.com/docs/getting-started/example-datasets/tpcds |
| NYC Taxi ClickHouse docs | https://clickhouse.com/docs/getting-started/example-datasets/nyc-taxi |
| NYC Taxi prepared partitions | https://datasets.clickhouse.com/trips_mergetree/partitions/trips_mergetree.tar |
| NYC Taxi 3M sample (S3) | https://datasets-documentation.s3.eu-west-3.amazonaws.com/nyc-taxi/trips_{0..2}.gz |
| OnTime ClickHouse docs | https://clickhouse.com/docs/getting-started/example-datasets/ontime |
| OnTime S3 snapshot | https://clickhouse-public-datasets.s3.amazonaws.com/ontime/csv_by_year/*.csv.gz |
| GitHub Events ClickHouse docs | https://clickhouse.com/docs/getting-started/example-datasets/github-events |
| clickhouse-benchmark docs | https://clickhouse.com/docs/operations/utilities/clickhouse-benchmark |
| Parallel replicas docs | https://clickhouse.com/docs/deployment-guides/parallel-replicas |
| Grafana dashboard #12163 | https://grafana.com/grafana/dashboards/12163-altinity-clickhouse-operator-dashboard |

---

*Plan authored: 2026-07 · Target cluster: 1×3 ReplicatedMergeTree on EKS · i8g.4xlarge (ARM/Graviton, 16 vCPU / 128 GiB) · Local NVMe 3.75 TB · Altinity Operator 0.27.1*
