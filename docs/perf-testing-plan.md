# ClickHouse 性能与压力测试计划
**中文** · [English](./perf-testing-plan.en.md)

### EKS 上的 1 分片 × 3 副本（i8g.4xlarge / ARM Graviton / 本地 NVMe）

**集群：** Altinity Operator 0.27.1 · ReplicatedMergeTree · 专用 i8g.4xlarge 节点上的 3× ClickHouse Pod · gp3 节点上的 3× Keeper
**访问：** 仅限 ClusterIP，所有负载均由集群内 Job Pod 或 `kubectl port-forward` 发起
**目标：** 找出单节点查询上限，验证读取能力可随 3 个副本近似线性扩展，对插入/合并吞吐量进行压力测试，并证明高可用能力在混沌场景下的韧性。

---

## A 部分 — 权威基准数据集

### 数据集快速参考

| # | 数据集 | 行数 | 压缩后大小 | 模式形态 | 主要压力点 | 最适合本集群的用途 |
|---|---------|------|-----------------|--------------|----------------|-----------------------|
| 1 | **ClickBench `hits`** | 99.9M | ~14 GB (Parquet) / ~15 GB (CSV.gz) | 1 张宽扁平表，105 列 | 全列扫描、过滤聚合、正则表达式、ORDER BY | **主要基准** — 单节点上限与 parallel_replicas |
| 2 | **SSB（星型模式基准）** | SF100 = 600M 行 (lineorder) | SF2500 时未压缩约 ~355 GB | 星型模式：1 张事实表 + 4 张维度表；非规范化扁平变体 | 多表 JOIN、聚合、带过滤条件的 GROUP BY | JOIN 开销、非规范化查询与星型查询对比 |
| 3 | **TPC-H** | SF100 = 600M 行 (lineitem) | SF100 时约 ~100 GB | 8 张规范化表，接近雪花模式 | 复杂子查询、多路 JOIN、大量排序 | 适配性有限 — CK 不是针对连接优化的 OLTP 引擎；仅用于完整性测试 |
| 4 | **TPC-DS** | SF200 = 1.4B 行 (store_sales) | SF200 时约 ~200+ GB | 24 表雪花模式，偏斜分布 | 99 个报表/即席查询、复杂 SQL | 非常有限 — 原生 CK 仅约 ~8/99 个查询能够完成；除非目标是 SQL 覆盖率，否则跳过 |
| 5 | **NYC Taxi** | 3B+ 次行程（完整）；~1.1B（2009–2015 历史数据） | 未压缩 CSV 约 ~227 GB（完整） | 1 张事实表，30–50 列，时间序列 | 时间范围聚合、GROUP BY、过滤扫描 | 插入吞吐量测试；真实世界的杂乱数据 |
| 6 | **OnTime（航空）** | ~200M 行 (1987–2022) | 未压缩约 ~141 GB | 1 张宽表，109 列 | 时序聚合、航空公司/机场 GROUP BY | 教程规模预热；多年范围扫描 |
| 7 | **GitHub Events** | 3.1B 条记录 (2011–2020) | 下载约 ~75 GB / 磁盘约 ~200 GB | 1 张半结构化宽表 | 大规模聚合、字符串搜索、LIKE | 大规模单节点上限验证；可放入 3.75 TB NVMe |

---

### A1 — ClickBench（`hits` 数据集）

**简介：** 这是标准的 ClickHouse 基准测试，创建于 2013 年十月，数据取自 Yandex Metrica 一周生产页面浏览量的 1/50。它包含约 ~99,997,497 行、105 列的真实 Web 分析数据（已匿名化）。查询集（43 个查询）涵盖全表扫描、过滤聚合、URL 字符串中的正则表达式搜索、带 LIMIT 的 ORDER BY，以及多列 GROUP BY。它是 [benchmark.clickhouse.com](https://benchmark.clickhouse.com/) 和 [benchmark.clickhouse.com/hardware/](https://benchmark.clickhouse.com/hardware/) 使用的标准参考。

**来源：** [https://github.com/ClickHouse/ClickBench](https://github.com/ClickHouse/ClickBench)
**仪表板：** [https://benchmark.clickhouse.com/](https://benchmark.clickhouse.com/)

**下载 URL（已根据 ClickBench GitHub README 验证）：**

| 格式 | URL |
|--------|-----|
| **CSV.gz** | `https://datasets.clickhouse.com/hits_compatible/hits.csv.gz`（压缩后 ~15 GB，未压缩 ~75 GB） |
| **TSV.gz** | `https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz` |
| **JSONlines.gz** | `https://datasets.clickhouse.com/hits_compatible/hits.json.gz` |
| **Parquet** | `https://datasets.clickhouse.com/hits_compatible/hits.parquet`（~14 GB，内部压缩） |
| **Parquet（100 个分区文件）** | `https://datasets.clickhouse.com/hits_compatible/athena_partitioned/hits_{0..99}.parquet` |

**模式：** 官方 DDL 位于 `https://github.com/ClickHouse/ClickBench/blob/main/clickhouse/create.sql`
**查询：** 官方 43 查询文件位于 `https://github.com/ClickHouse/ClickBench/blob/main/clickhouse/queries.sql`

**ClickHouse 摄取后的磁盘占用：** ~14.21 GiB（ClickHouse 原生列式压缩，使用 LZ4）。来源：[ClickHouse OLAP 排名页面，2026 年五月](https://clickhouse.com/resources/engineering/fastest-olap-databases)。

**与本集群的相关性：**
- 用于找出单节点查询上限的主要基准（查询 Q3、Q6、Q12、Q14、Q33–Q43 是会使 16 个 vCPU 饱和的 CPU/扫描密集型查询）。
- 14 GB 数据集仅占 3.75 TB NVMe 的较小比例,可在一次加载后重复执行测试。
- 直接支持 `parallel_replicas` 开启与关闭的对比（见下文步骤 C2）。

---

### A2 — 星型模式基准（SSB）

**简介：** 这是 O'Neil 等人（2009）提出的 OLAP 基准，派生自 TPC-H，但重构为标准星型模式。事实表（`lineorder`）周围有四张维度表（`customer`、`supplier`、`part`、`date`）。分为 4 个“flight”的 13 个查询用于测试 JOIN + GROUP BY + 过滤条件的组合。ClickHouse 文档还涵盖了一个**非规范化扁平变体**（`lineorder_flat`），该变体消除 JOIN，将 SSB 转化为单张宽表扫描，可公平测试 CK 的列式聚合能力。

**缩放因子：** `-s 1` ≈ 6M 行；`-s 100` ≈ 600M 行 (lineorder)；`-s 2500` ≈ 15B 行（Altinity 和 Percona 在已发布测试中使用）。

**数据生成器：**
```bash
git clone https://github.com/vadimtk/ssb-dbgen.git
cd ssb-dbgen && make
./dbgen -s 100 -T c   # customer
./dbgen -s 100 -T l   # lineorder
./dbgen -s 100 -T p   # part
./dbgen -s 100 -T s   # supplier
./dbgen -s 100 -T d   # date
```
来源：[ClickHouse 文档 — 星型模式基准](https://clickhouse.com/docs/getting-started/example-datasets/star-schema)

**日期格式说明：** 原版 dbgen 输出的日期格式为 `19971125`；ClickHouse 要求 `1997-11-25`。位于 `https://github.com/vadimtk/ssb-dbgen` 的 Altinity 分支包含此修复。来源：[Altinity 博客，2017](https://altinity.com/blog/2017-6-16-clickhouse-in-a-general-analytical-workload-based-on-star-schema-benchmark)。

**与本集群的相关性：** SF100（600M 行，原始数据约 ~60 GB）非常适合放在 NVMe 上。扁平表变体可直接与 ClickBench 的扫描模式进行比较。星型模式变体用于测试 JOIN 性能，这对 CK OLAP 服务层而言是次要关注点，但有助于刻画查询计划。

---

### A3 — TPC-H

**简介：** 事务处理性能委员会的决策支持基准（1999）。包含 8 张表、22 个带有复杂多路 JOIN、子查询和聚合的查询。SF100 在 `lineitem`（主事实表）中生成约 ~600M 行，总计产生约 ~100 GB 原始数据。

**生成器：**
```bash
git clone https://github.com/gregrahn/tpch-kit.git
cd tpch-kit/dbgen && make
./dbgen -s 100      # SF100 = ~100 GB
```
来源：[ClickHouse 文档 — TPC-H](https://clickhouse.com/docs/getting-started/example-datasets/tpch)

**ClickHouse 还通过 S3 提供预置的 SF1 数据**（`INSERT INTO nation SELECT * FROM s3('...', NOSIGN, CSV)` 语法请参阅 ClickHouse 文档）。

**客观评估：** ClickHouse 并未针对 TPC-H 风格的多连接雪花查询进行优化。在一项已发布的正面对比（Exasol 与 ClickHouse，2025 年十月）中，22 个查询上 CK 的 TPC-H 运行时间中位数为 2,546 ms，而 Exasol 为 238 ms。包含深层多路 JOIN 的查询（Q17、Q21）差距最大。本计划仅使用 TPC-H 来刻画 JOIN 性能限制，不将其作为主要基准。

---

### A4 — TPC-DS

**简介：** 24 表雪花模式、99 个查询、偏斜分布（泊松/正态）。有效缩放因子：100、300、1000、3000+ GB。来源：[ClickHouse 文档 — TPC-DS](https://clickhouse.com/docs/getting-started/example-datasets/tpcds)

**客观评估：** 在一项独立基准测试（Radiant Advisors，2024）中，ClickHouse 在 SF200 下仅完成了 99 个 TPC-DS 查询中的 8 个。除非正在测试 SQL 兼容性，否则**本计划跳过 TPC-DS**。此处列出仅为保持完整性。

---

### A5 — NYC Taxi 数据集

**简介：** 纽约市 TLC 出租车行程记录。常见的两种规模：
- **样本（3M 行）：** S3 URL `https://datasets-documentation.s3.eu-west-3.amazonaws.com/nyc-taxi/trips_{0..2}.gz`
- **完整预处理分区：** `https://datasets.clickhouse.com/trips_mergetree/partitions/trips_mergetree.tar`（未压缩约 ~227 GB，包含截至 2024 年的 FHV/Uber/Lyft 数据，共 3B+ 行）
- **历史数据 1.1B 行（2009–2015）：** Mark Litwintschik 位于 `s3://nyc-tlc/trip data/` 的 56 文件数据集（GZIP CSV，压缩后 104 GB，解压后 500 GB）。来源：[tech.marksblogg.com](https://tech.marksblogg.com/billion-taxi-rides-doublecloud-clickhouse.html)

ClickHouse 加载说明来源：[ClickHouse 文档 — NYC Taxi](https://clickhouse.com/docs/getting-started/example-datasets/nyc-taxi)

**相关性：** 1.1B 行的历史数据集（未压缩 500 GB，在 ClickHouse MergeTree 中约 ~144 GB）是进行**插入吞吐量压力测试**的最佳数据集，其规模足以使插入管线饱和并触发大量合并活动。它可以放入 3.75 TB NVMe，并留有余量。

---

### A6 — OnTime（航空准点表现）

**简介：** 美国交通统计局 1987–2022 年的航班数据。约 ~200M 行，109 列。来源：[ClickHouse 文档 — OnTime](https://clickhouse.com/docs/getting-started/example-datasets/ontime)

**从 ClickHouse 的 S3 快照加载：**
```sql
INSERT INTO ontime SELECT * FROM s3(
  'https://clickhouse-public-datasets.s3.amazonaws.com/ontime/csv_by_year/*.csv.gz',
  CSVWithNames
) SETTINGS max_insert_threads = 16;
```

**相关性：** 适合作为预热/冒烟测试数据集。200M 行可以快速摄取（在 NVMe 上约 ~30 min），时序查询集（按年/月/航空公司聚合）能够代表 BI 服务查询。

---

### A7 — GitHub Events（大规模验证）

**简介：** 2011 年至 2020 年十二月 6 日的所有 GitHub 事件。3.1B 条记录，下载大小 75 GB，使用 LZ4 压缩后的磁盘占用约 ~200 GB。来源：[ClickHouse 文档 — GitHub Events](https://clickhouse.com/docs/getting-started/example-datasets/github-events) 和 [GitHub 仓库](https://github.com/ClickHouse/github-explorer)。

**相关性：** 该数据集压缩后为 200 GB，可放入 3.75 TB NVMe，无需多文件编排即可提供真实的“大规模”单节点上限测试。它非常适合验证在正确建立索引后，3B+ 行的扫描仍能保持亚秒级响应，也适合对高基数 GROUP BY 下的内存进行压力测试。

---

### 本计划的数据集选择摘要

| 测试目标 | 推荐数据集 |
|-----------|---------------------|
| 单节点查询上限（扫描速度） | ClickBench `hits`（100M 行，14 GB） |
| `parallel_replicas` 开启与关闭的加速对比 | ClickBench `hits` — 使用相同查询 |
| 读取并发/QPS 递增 | ClickBench `hits`（热缓存） |
| 插入/合并吞吐量压力 | NYC Taxi 1.1B 行或 GitHub Events |
| JOIN 性能刻画 | SSB SF100 扁平变体 + 星型变体 |
| 大规模单节点验证 | GitHub Events（3.1B 行） |

---

## B 部分 — 工具

### B1 — `clickhouse-benchmark`（内置负载生成器）

该工具随 `clickhouse-client` 一同提供，是进行并发度 + QPS + 延迟百分位基准测试的标准机制。

**关键参数**（来自 [ClickHouse 文档](https://clickhouse.com/docs/operations/utilities/clickhouse-benchmark)）：

| 参数 | 默认值 | 用途 |
|------|---------|---------|
| `-c / --concurrency=N` | 1 | 同时运行的查询线程数（主要的“负载”调节项） |
| `-C / --max_concurrency=N` | — | 从 1 递增到 N（分级负载扫描） |
| `-i / --iterations=N` | 0（无限） | 要发送的查询总数 |
| `-t / --timelimit=N` | 0 | N 秒后停止 |
| `-r / --randomize` | 关闭 | 从文件中随机选择查询（避免有序查询的缓存效应） |
| `--delay=N` | 1 | 进度报告之间的秒数 |
| `--cumulative` | 关闭 | 输出累计统计而非每个时间间隔的统计 |
| `--continue_on_errors` | 关闭 | 查询出错时不中止（压力测试需要） |
| `--host=H --port=P` | localhost:9000 | 目标；指定多组参数可对两台服务器进行统计比较 |
| `--roundrobin` | 关闭 | 每个查询在各 `--host` 条目间轮询（用于将负载分散到 3 个副本） |

**每个报告间隔的输出指标：**
- `QPS` — 每秒查询数
- `RPS` — 每秒读取行数
- `MiB/s` — 数据读取吞吐量
- 0%、10%、20%、…、95%、99%、99.9%、99.99% 延迟百分位

**比较模式：** 指定 `--host=A --port=9000 --host=B --port=9000` 可并行运行两台服务器，并以可配置的置信度获得 Student t 检验的显著性结果。

**基本调用方式：**
```bash
cat queries.sql | clickhouse-benchmark \
  --host=clickhouse-ch.clickhouse.svc.cluster.local \
  --port=9000 \
  --concurrency=8 \
  --iterations=200 \
  --randomize \
  --delay=5
```

### B2 — ClickBench 官方测试工具

ClickBench 仓库（`https://github.com/ClickHouse/ClickBench`）包含针对各系统的 `benchmark.sh` 脚本。ClickHouse 的标准单次运行方式如下：

```bash
# Run each of the 43 queries 3 times; report cold (run 1) and hot (min of run 2,3)
while read -r query; do
  clickhouse-client --query "$query" --format Null  # warm
  clickhouse-client --query "$query" --time --format Null 2>&1 | tail -1
  clickhouse-client --query "$query" --time --format Null 2>&1 | tail -1
done < queries.sql
```

`benchmark.clickhouse.com` 上发布的排行榜使用 `c6a.4xlarge` 作为参考机器。`i8g.4xlarge`（Graviton，16 vCPU / 128 GiB）的 Neoverse V2 核心具有不同的内存带宽和指令集特征,因此排行榜结果只能作为参考;扫描密集型查询的实际差异需由本计划测量。

### B3 — 用于采集指标的系统表

所有查询均直接针对相应的 ClickHouse Pod 运行。

**单查询性能（事后分析）：**
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

**合并积压（插入压力）：**
```sql
SELECT database, table, elapsed, progress, num_parts, source_part_names, result_part_name
FROM system.merges
ORDER BY elapsed DESC;
```

**复制延迟（高可用/混沌测试）：**
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

**复制事件计数器（服务器启动后的累计值）：**
```sql
SELECT event, value FROM system.events
WHERE event IN ('ReplicatedPartFetches','ReplicatedPartFetchesOfMerged','ReplicatedDataLoss');
-- ReplicatedDataLoss must stay 0
```

**服务器实时内存：**
```sql
SELECT metric, value
FROM system.asynchronous_metrics
WHERE metric IN (
    'MemoryResident', 'MemoryVirtual',
    'jemalloc.resident', 'jemalloc.mapped'
);
```

**当前连接数/查询并发度：**
```sql
SELECT metric, value FROM system.metrics
WHERE metric IN ('Query', 'Merge', 'ReplicatedFetch', 'Connection');
```

### B4 — Prometheus / Grafana

Altinity Operator 通过 metrics-exporter sidecar 自动向 Prometheus 暴露 ClickHouse 指标。官方仪表板如下：

- **Grafana 仪表板 ID 12163** — “Altinity ClickHouse Operator Dashboard”
  URL: [https://grafana.com/grafana/dashboards/12163-altinity-clickhouse-operator-dashboard](https://grafana.com/grafana/dashboards/12163-altinity-clickhouse-operator-dashboard)

将仪表板 12163 导入集群内 Grafana（`kubectl port-forward svc/grafana 3000:3000 -n monitoring`）。测试期间的关键面板：
- `ClickHouseMetrics_Query` — 实时并发查询数
- `ClickHouseAsynchronousMetrics_MemoryResident` — 每个 Pod 的 RSS 内存
- `ClickHouseMetrics_ReplicatedFetch` — 活跃副本拉取线程数（高可用恢复期间会出现峰值）
- 来自 Kubernetes 节点指标的 CPU/网络吞吐量

### B5 — 集群内负载驱动器：Kubernetes Job 规范

由于只能通过 ClusterIP 访问，所有 `clickhouse-benchmark` 调用都作为 Kubernetes Job 在集群内运行。服务 `clickhouse-ch`（ClusterIP）在全部 3 个 Pod 之间进行负载均衡。

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
        image: clickhouse/clickhouse-server:25.3-alpine   # matches cluster version
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
              --host=clickhouse-ch.clickhouse.svc.cluster.local \
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

对于 `clickhouse-benchmark` 并发度扫描，将命令块替换为：

```bash
clickhouse-benchmark \
  --host=clickhouse-ch.clickhouse.svc.cluster.local \
  --port=9000 \
  --concurrency="${CONCURRENCY:-8}" \
  --timelimit=120 \
  --randomize \
  --delay=10 \
  --continue_on_errors \
  < /tmp/queries.sql
```

---

## C 部分 — 分阶段测试计划

### 前置条件

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

### 阶段 1 — 数据加载

**数据集：** ClickBench `hits`（主要基准）+ NYC Taxi 1.1B 行（插入压力）

**步骤 1a — 创建 `hits` 表（ReplicatedMergeTree）：**

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

**步骤 1b — 从 S3 加载 hits（无需本地下载）：**

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

加载期间监控复制：
```sql
-- Poll every 30s from a second pod to confirm replication is keeping up
SELECT replica_name, absolute_delay, queue_size, inserts_in_queue
FROM system.replicas WHERE table = 'hits';
```

**预期：** 从 S3 加载到一个副本需要 5–10 min；全部 3 个副本在 15 min 内完成同步。每个副本的磁盘占用：~14 GiB。整个集群使用的 NVMe 总量：42 GiB（14 GiB × 3）。

**步骤 1c — 验证行数：**
```sql
SELECT count() FROM bench.hits;
-- Expected: 99,997,497
```

**步骤 1d — 加载 NYC Taxi 1.1B 行（用于阶段 4 的插入压力测试）：**

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

**NVMe 容量检查：** ClickHouse 将出租车数据压缩到约 1 byte/row。1.1B 行 ≈ 每个副本 ~144 GB × 3 个副本 = NVMe 总计 ~432 GB。远低于每个节点的 3.75 TB。

---

### 阶段 2 — 性能测试：单查询上限

**目标：** 运行完整的 ClickBench 43 查询套件；识别会使单个节点的 16 个 vCPU 饱和的扫描密集型查询（“纵向扩展瓶颈”）；然后针对这些查询测试 `parallel_replicas` 开启与关闭的效果。

**步骤 2a — 基线：43 个查询、单副本、不使用 parallel_replicas：**

部署集群内 Job：
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

注意：直接使用 Pod 地址（`chi-clickhouse-0-0-0.clickhouse-headless.…`）会绕过 ClusterIP 负载均衡器，并将查询固定到一个副本。Altinity Operator 会创建用于 Pod 级寻址的无头服务。

**步骤 2b — 识别“纵向扩展瓶颈”查询：**

通常会使 16 vCPU 节点的 CPU 饱和的查询（基于已发布的 ClickBench 结果）：
- **Q6** — 全表扫描上的 `count()`（受存储吞吐量限制）
- **Q12、Q14** — UserID 上的 `uniq()`（高基数、内存带宽）
- **Q33–Q43** — 复杂多列聚合、URL 列中的正则表达式

运行后从 `system.query_log` 采集：
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

**通过标准：** 全部 43 个查询均完成且没有 OOM。`query_duration_ms > 5000` 的查询是使用 `parallel_replicas` 优化的候选项。

**步骤 2c — `parallel_replicas` 开启与关闭的对比：**

启用 `parallel_replicas`，重新运行最慢的 5 个查询。这是对 1×3 拓扑“虚拟分片”能力的关键验证。

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

来源：[ClickHouse 文档 — 并行副本](https://clickhouse.com/docs/deployment-guides/parallel-replicas)

**通过标准：** `parallel_replicas = 3` 将扫描密集型查询的实际耗时减少 ≥ 2×（理论最大值：3×；考虑协调开销，实际为 2–2.5×）。这证明了该设计理念中关于 `parallel_replicas` 可以推迟真正分片需求的主张。

**预期参考：** 根据一篇 ClickHouse Cloud 博客文章（[clickhouse.com/blog/clickhouse-parallel-replicas](https://clickhouse.com/blog/clickhouse-parallel-replicas)），一个 30M 行的 GROUP BY 在单节点上用时 33 ms；在同等硬件上使用 3 个并行副本时，观察到低于 15 ms 的结果。你的 16 vCPU/128 GiB Graviton 节点非常适合此测试。

---

### 阶段 3 — 读取并发度/QPS 递增

**目标：** 使用 `clickhouse-benchmark` 访问 **ClusterIP 服务**（它在全部 3 个副本之间轮询），将 `--concurrency` 从 1 递增到 64。绘制 QPS + p50/p95/p99 延迟。找出延迟出现拐点的“膝点”。

**步骤 3a — 并发度扫描 Job：**

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
        image: clickhouse/clickhouse-server:25.3-alpine
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
              --host=clickhouse-ch.clickhouse.svc.cluster.local \
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

**步骤 3b — 从日志中提取汇总指标：**
```bash
# Parse QPS from each log
for f in /tmp/concurrency_*.log; do
  CONC=$(echo $f | grep -o '[0-9]*\.log' | tr -d '.log')
  QPS=$(grep 'QPS:' $f | tail -1 | awk -F'QPS: ' '{print $2}' | awk '{print $1}')
  P99=$(grep '99.000%' $f | tail -1 | awk '{print $2}')
  echo "concurrency=$CONC qps=$QPS p99=$P99"
done
```

**步骤 3c — 观察各副本间的读取分布：**

扫描运行期间，在任意 Pod 中执行：
```sql
-- Confirms queries are spread across all 3 replicas
SELECT hostname(), count() AS queries_handled
FROM clusterAllReplicas('{cluster}', system.query_log)
WHERE type = 'QueryFinish'
  AND event_time > now() - INTERVAL 5 MINUTE
GROUP BY hostname()
ORDER BY hostname();
```

**通过标准：**
- 在 concurrency=3（每个副本一个查询）时，QPS 应达到 concurrency=1 基线的 ≥ 3×，从而确认读取能力近似线性扩展。
- concurrency=8 时的 p99 延迟应 ≤ concurrency=1 时 p50 的 3×（可接受的性能下降）。
- “膝点”（p99 开始超线性增长的位置）应出现在 concurrency = 3 × `max_threads_per_query` 附近（对于 16 vCPU 节点、3 个副本，约为 48）。

**本阶段要调整的扩展参数：**
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

### 阶段 4 — 插入/合并吞吐量压力

**目标：** 向 3 副本集群持续进行高速插入；测量写放大（3× 网络流量）、合并积压累积和复制延迟。在 `absolute_delay` 超过告警阈值之前找出插入上限。

**步骤 4a — 持续插入 Job（NYC Taxi 1.1B 行）：**

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
        image: clickhouse/clickhouse-server:25.3-alpine
        command:
        - /bin/bash
        - -c
        - |
          # Stream inserts from S3 in large batches
          # Each INSERT block = 1M rows (respects max_insert_block_size)
          clickhouse-client \
            --host=clickhouse-ch.clickhouse.svc.cluster.local \
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

**步骤 4b — 插入期间监控（从第二个终端每 10s 轮询一次）：**

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

**步骤 4c — 找出插入上限：**

逐步增加 `--parallel` 插入 Job（1、2、4 个并发插入流），并观察：
```sql
-- Warning sign: too many parts (merge can't keep up)
SELECT count() AS part_count FROM system.parts WHERE table = 'trips' AND active;
-- ALERT if > 300 active parts per partition
```

当任意副本上的 `inserts_in_queue` 超过 100 且 `absolute_delay` 超过 60 seconds 时，即已找到插入上限。

**带宽限流参数**（来自项目的最佳实践说明）：
```xml
<!-- In config.d/replica-fetch-throttle.xml — limits replica fetch to leave bandwidth for queries -->
<max_replicated_fetches_network_bandwidth_for_server>
  500000000  <!-- 500 MB/s; tune down to 100 MB/s during sustained inserts -->
</max_replicated_fetches_network_bandwidth_for_server>
```

**通过标准：**
- 持续插入速率 ≥ 500K rows/sec（单个流写入 1 个副本）
- 单流插入期间，任意副本上的 `absolute_delay` 均保持 < 60 s
- 全程 `ReplicatedDataLoss` 计数器 = 0
- 插入停止后，合并队列在 5 minutes 内清空

---

### 阶段 5 — 高可用/韧性（混沌测试）

**目标：** 在读取负载下删除一个副本 Pod；确认 QPS 下降约 ~1/3，但服务继续运行且没有错误；测量 Pod 恢复后的恢复时间。

**步骤 5a — 建立读取基线：**

针对 ClusterIP 服务启动后台并发扫描（concurrency=4）：
```bash
# In terminal 1: run from in-cluster pod
clickhouse-benchmark \
  --host=clickhouse-ch.clickhouse.svc.cluster.local \
  --port=9000 \
  --concurrency=4 \
  --timelimit=300 \
  --randomize \
  --delay=5 \
  --continue_on_errors \
  < /tmp/queries.sql &
```

记录基线 QPS 和 p99。

**步骤 5b — 终止一个副本：**
```bash
# In terminal 2 (external / kubectl)
# Record which pod is being killed
kubectl -n clickhouse delete pod chi-clickhouse-0-0-2

# Kubernetes will reschedule the pod; the operator restores it
# The 2 remaining replicas continue serving queries
```

**步骤 5c — 观察性能下降与恢复：**

预期行为：
1. ClusterIP 服务移除已删除 Pod 的端点（Kubernetes 就绪探针 → 端点控制器）。发往故障 Pod 的查询超时/失败；`--continue_on_errors` 使基准测试继续运行。
2. 在 30–60 seconds 内，负载均衡器移除故障端点。QPS 下降约 ~1/3（活跃副本从 3 个减少到 2 个）。
3. Pod 重启；ClickHouse 进程启动并向 Keeper 注册。
4. Keeper 检测到缺失的数据部件；正在恢复的副本从存活副本拉取数据部件（“副本拉取”快速路径，即复制已经合并的数据部件，而不是单独的 INSERT 块）。

监控恢复：
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

恢复期间的 Prometheus 指标：
```
ClickHouseMetrics_ReplicatedFetch > 0  -- indicates active part fetching
```

**步骤 5d — 使用插入仲裁的高可用测试（可选，用于验证写入持久性）：**
```sql
-- This setting requires write acknowledgment from ≥ 2 replicas
-- before INSERT returns. Demonstrates that 1-replica failure doesn't lose data.
SET insert_quorum = 2;
SET insert_quorum_parallel = 0;
INSERT INTO bench.hits SELECT * FROM system.numbers LIMIT 100000;
```

**通过标准：**
- Pod 删除后：QPS 在 60 s 内降至基线的约 ~2/3，而不是降至 0
- `clickhouse-benchmark` 输出中的错误率：在 30 s 过渡窗口内 < 5%
- 全程 `ReplicatedDataLoss` 计数器 = 0
- Pod 重启后，`absolute_delay` 在以下时间内恢复到 < 10 s：
  - 如果每个副本的数据大小 < 100 GB，则为 **5 min**（NVMe 快速路径，直接复制 MergeTree 数据部件）
  - 如果每个副本的数据大小为 100–500 GB，则为 **20 min**
- 结束测试前确认 `active_replicas` = 3

**恢复带宽参数：** 如果恢复过程与读取负载争用资源：
```xml
<max_replicated_fetches_network_bandwidth_for_server>
  200000000  <!-- 200 MB/s → recovers 100 GB in ~8 min while leaving ~800 MB/s for reads -->
</max_replicated_fetches_network_bandwidth_for_server>
```
来源：[最佳实践说明 §6](../docs/notes-ck-on-eks-best-practices-2026.md)

---

### 阶段 6 — 指标采集与通过/失败标准摘要

| 阶段 | 关键指标 | 通过阈值 | 测量方法 |
|-------|-----------|----------------|----------------|
| 1（加载） | 全部 3 个副本上的行数 | = 99,997,497 | 在每个 Pod 上执行 `SELECT count() FROM bench.hits` |
| 1（加载） | 复制同步时间 | 插入完成后 < 15 min | `system.replicas.absolute_delay` = 0 |
| 2a（单查询） | 全部 43 个查询完成 | 无 OOM、无超时 | `system.query_log WHERE type='QueryError'` = 0 |
| 2a（单查询） | 热查询时间中位数 | 80% 的查询 < 1 s | 基准脚本的单查询计时 |
| 2c（parallel_replicas） | 重查询加速比 | 相对于单副本基线 ≥ 2× | 实际耗时比较（query_duration_ms） |
| 3（读取 QPS） | concurrency=3 时的 QPS | ≥ concurrency=1 时 QPS 的 3× | `clickhouse-benchmark` 输出 |
| 3（读取 QPS） | concurrency=8 时的 p99 延迟 | ≤ concurrency=1 时 p50 的 3× | `clickhouse-benchmark` 百分位输出 |
| 3（读取 QPS） | 查询分布 | 查询分散到全部 3 个副本，偏差 ± 15% | `clusterAllReplicas` query_log 计数 |
| 4（插入） | 持续插入速率 | ≥ 500K rows/sec | 每分钟的 `system.query_log.written_rows` |
| 4（插入） | 复制延迟 | `absolute_delay` < 60 s | `system.replicas` |
| 4（插入） | 数据丢失 | `ReplicatedDataLoss` = 0 | `system.events` |
| 5（高可用） | 服务连续性 | QPS > 0，终止 Pod 期间错误率 < 5% | `clickhouse-benchmark --continue_on_errors` |
| 5（高可用） | QPS 下降 | QPS 降至约 ~2/3，而不是 0 | `clickhouse-benchmark` 间隔报告 |
| 5（高可用） | 恢复时间 | 20 min 内 `absolute_delay` < 10 s | 轮询 `system.replicas` |

---

### 阶段 7 — 扩展参数参考

所有设置都应在启用前于 B 部分（基线）中进行测试。每次只更改一个设置。

| 参数 | 默认值 | 测试值 | 预期效果 | 阶段 |
|------|---------|------------|-----------------|-------|
| `enable_parallel_replicas` | 0 | 1 | 将单个查询分发到 3 个副本；重扫描加速 2–3× | 2c |
| `max_parallel_replicas` | 1000 | 3 | 上限设为 3（与集群大小匹配） | 2c |
| `cluster_for_parallel_replicas` | — | `'clickhouse'`（你的 CHI 集群名称） | parallel_replicas 工作所必需 | 2c |
| `parallel_replicas_min_number_of_rows_per_replica` | 0 | 10,000,000 | 防止对小查询使用 parallel_replicas（避免协调开销） | 2c |
| `enable_analyzer` | 不同版本有所不同 | 1 | parallel_replicas 所必需；同时启用现代查询规划器 | 2c |
| `max_threads` | = vCPUs | 8 或 16 | 控制查询内并行度；降低该值可为并发查询留出余量 | 3 |
| `load_balancing` | `random` | `round_robin` | 在 Distributed/客户端层面严格轮询各副本 | 3 |
| `max_replicated_fetches_network_bandwidth_for_server` | 0（无限制） | 200MB/s | 限制副本恢复速度以保护读取 QPS | 4、5 |
| `insert_quorum` | 0 | 2 | INSERT 返回前要求 2/3 个副本确认；在持久性与延迟之间权衡 | 4（可选） |
| `max_insert_threads` | 1 | 14 | 并行执行 S3→ClickHouse 摄取；批量加载期间占满所有 CPU | 1 |

---

## 附录 — 快速参考

### 已验证的来源 URL

| 资源 | 已验证的 URL |
|----------|-------------|
| ClickBench GitHub | https://github.com/ClickHouse/ClickBench |
| ClickBench 仪表板 | https://benchmark.clickhouse.com/ |
| ClickBench 硬件排行榜 | https://benchmark.clickhouse.com/hardware/ |
| hits.parquet | https://datasets.clickhouse.com/hits_compatible/hits.parquet |
| hits.csv.gz | https://datasets.clickhouse.com/hits_compatible/hits.csv.gz |
| hits.tsv.gz | https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz |
| hits 分区文件（100 个文件） | https://datasets.clickhouse.com/hits_compatible/athena_partitioned/hits_{0..99}.parquet |
| ClickBench create.sql | https://github.com/ClickHouse/ClickBench/blob/main/clickhouse/create.sql |
| ClickBench queries.sql | https://github.com/ClickHouse/ClickBench/blob/main/clickhouse/queries.sql |
| SSB dbgen（Altinity 分支） | https://github.com/vadimtk/ssb-dbgen |
| SSB ClickHouse 文档 | https://clickhouse.com/docs/getting-started/example-datasets/star-schema |
| TPC-H ClickHouse 文档 | https://clickhouse.com/docs/getting-started/example-datasets/tpch |
| TPC-DS ClickHouse 文档 | https://clickhouse.com/docs/getting-started/example-datasets/tpcds |
| NYC Taxi ClickHouse 文档 | https://clickhouse.com/docs/getting-started/example-datasets/nyc-taxi |
| NYC Taxi 预处理分区 | https://datasets.clickhouse.com/trips_mergetree/partitions/trips_mergetree.tar |
| NYC Taxi 3M 样本（S3） | https://datasets-documentation.s3.eu-west-3.amazonaws.com/nyc-taxi/trips_{0..2}.gz |
| OnTime ClickHouse 文档 | https://clickhouse.com/docs/getting-started/example-datasets/ontime |
| OnTime S3 快照 | https://clickhouse-public-datasets.s3.amazonaws.com/ontime/csv_by_year/*.csv.gz |
| GitHub Events ClickHouse 文档 | https://clickhouse.com/docs/getting-started/example-datasets/github-events |
| clickhouse-benchmark 文档 | https://clickhouse.com/docs/operations/utilities/clickhouse-benchmark |
| 并行副本文档 | https://clickhouse.com/docs/deployment-guides/parallel-replicas |
| Grafana 仪表板 #12163 | https://grafana.com/grafana/dashboards/12163-altinity-clickhouse-operator-dashboard |

---

*计划编写时间：2026-07 · 目标集群：EKS 上的 1×3 ReplicatedMergeTree · i8g.4xlarge（ARM/Graviton，16 vCPU / 128 GiB）· 本地 NVMe 3.75 TB · Altinity Operator 0.27.1*
