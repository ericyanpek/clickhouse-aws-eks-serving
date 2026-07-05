# ClickHouse on EKS —— 生产最佳实践笔记（2026-07）

> 缘起：从 awslabs data-on-eks 的 clickhouse-on-eks reference stack（Altinity Operator + Keeper + Karpenter + ArgoCD，示例 3×3）出发，逐层推演，落成一套自己的部署主张。
> 参考页：https://awslabs.github.io/data-on-eks/docs/datastacks/databases/clickhouse-on-eks

---

## 0. 这套最佳实践的适用边界（先说清楚 scope）

**这套主张是针对一个具体定位的：CK 作为"湖仓/数仓下游的、轻量 OLAP / BI serving 加速层"，不做主数仓、不当唯一 source of truth。**

在这个定位下，下面所有取舍都自洽且接近最优。但它不是"CK on EKS 唯一正确解"——以下情况取舍会变，别硬套：

- CK 必须是**主存储 / 唯一 SoT**（没有上游湖仓兜底）→ durability 要求陡增，本地 NVMe 那套不成立，得回到 EBS + 备份为主。
- **极高吞吐实时摄入**（如大规模 Kafka 直灌、写重于读）→ 写放大成为主约束，副本策略、分片策略都要重估。
- **超大规模、单查询要跨很多机器扇出** → 必须真正分片，1-shard scale-up 顶不住。

**结论：叫它"CK 作为湖仓派生 serving 层在 EKS 上的最佳实践"更准确。范围内它很强；别当成放之四海皆准的通用模板。**

---

## 1. 拓扑基本功（先把概念钉死，后面全靠这个）

### shard = 按行水平切分，不是按列
- 每个 shard 存全表的一个**行子集**，schema 相同；拼起来才是全表。
- CK 是列存，但"列存"是**单节点内**磁盘按列组织；"分片"是**跨节点**按行切。两个正交维度。**不存在列级分片。**
- 分到哪个 shard 由 sharding key 的 hash 决定（reference 用 `cityHash64(UserID)`）。近似均衡，**不保证严格等分**——key 倾斜会导致某 shard 偏胖。
- shard 数最小是 **1**（不存在 0）。任意正整数都合法（2/4/7…）。

### replica = 同一 shard 的完整数据拷贝，multi-master，无主从
- **关键纠偏**：CK 的 ReplicatedMergeTree 是**多主对等（masterless）**，不是 MySQL/PG/Redis 那种 primary-replica。
  - 没有"主副本"角色，**没有主从选举、没有故障 promotion**。
  - 每个副本都能读能写；挂一个，其余照常，重启后自己去 Keeper 对账追平。
  - （历史包袱：老版本有个 "leader" 只管调度 merge，与读写无关；20.5 后多 leader，该瓶颈基本消失。别用"主/从"套 CK。）
- 副本数**无奇偶要求**（2/4 都行）。⚠️ 别和 **Keeper** 混——Keeper 是 Raft，要奇数（3/5）凑 quorum；**数据副本不走 quorum**（默认异步复制）。

### 两个维度各解决什么（核心心智）
```
想让"一个查询"更快 / 装更多数据  →  加 SHARD（横向切分，按行）
想扛更多"并发查询" / 挂机不停服  →  加 REPLICA（冗余，多主对等）
```

### 和 Kafka/MSK 的类比（挪一格才对）
```
Kafka partition  ≈  CK SHARD    ← 并行/切分单元
Kafka replica    ≈  CK REPLICA  ← 冗余单元
```
- 并行度来自 shard，不来自 replica（同 Kafka：并行来自 partition 数）。
- **差异**：Kafka follower 默认不对外服务（KIP-392 后才有 follower read）；**CK 副本全部可读**。

---

## 2. 推荐起手式：1 shard × 3 replica + 大节点（scale-up 优先）

**CK 的正确心法是"先垂直做大单节点，分片是最后手段"**，因为：
- 单节点 CK 能扛的数据量远超直觉（压缩后 TB 级毫无压力）。
- **re-sharding 极痛**：CK 无自动 rebalance，加 shard 后老数据不自动搬，得手动 `INSERT SELECT` 重灌或 `clickhouse-copier`。

所以推荐默认形态：**不分片（shardsCount: 1）+ 3 副本 + 每副本独占一台大 Graviton，跨 3 AZ。**

```
        replica r1        replica r2        replica r3
       ┌──────────┐      ┌──────────┐      ┌──────────┐
       │ 大 pod   │ ≈≈≈  │ 大 pod   │ ≈≈≈  │ 大 pod   │   全量数据 × 3 份完整拷贝
       │  AZ-a    │      │  AZ-b    │      │  AZ-c    │
       └──────────┘      └──────────┘      └──────────┘
   1 个 shard = 每节点都有全表，无横向切分；每 pod 独占一台 EC2
```

**为什么这是最优起手：**
- ✅ 零 re-sharding 痛点（永远不用面对 CK 最痛的运维）。
- ✅ 无跨 shard 扇出，查询路径最短，无 coordinator 多 shard 聚合开销。
- ✅ HA + 读扩展都到位：挂 1 台仍有 2 份；读 QPS 近似 3×。
- ✅ 扩容极简：读不够→加副本（加个 STS，不动数据布局）；资源不够→换更大机型。都不碰数据切分。

**两个必记点：**
1. **Keeper 不能省**。只要用 `Replicated` 引擎，复制协调就走 Keeper，**与 shard 数无关**。1×3 照样要 3 节点 Keeper ensemble。常见误解："不分片就不用 Keeper"——错。
2. **不用 Distributed 表**。1 shard 下每副本都有全量，无跨节点扇出必要。Distributed 只会平白加一跳。客户端前挂 LB 轮询到 3 个 pod，**直接查 ReplicatedMergeTree 本地表**，读自动摊到 3 副本。

**什么时候撞墙 → 才引入 shard（三条线，撞任一）：**
1. 单节点存不下全量（压缩后超单机盘 / 超机型可挂最大 EBS/NVMe）。
2. **单条大聚合太慢**——1 shard 下一个查询只能吃一台的算力，副本不加速单查询。扫大半表的重聚合会被单机 CPU 卡死。（最常见的隐性上限）
3. 写入吞吐超单节点上限（较少见）。

**推迟撞墙的杀手锏：`parallel_replicas`**。开启后一个查询能同时调用同 shard 的多个副本并行扫同一份数据，等于让"副本"临时兼职"shard"，单查询也拿到 N× 并行。在 1-shard 拓扑下尤其值钱——卡在"单查询慢"但还不想真分片时，先开这个往往能把分片再往后推很久。（成熟度：近版本趋稳，锁版本时查 changelog。）

---

## 3. Sizing 量化

### Shard 数 vs 数据量
不是拿总量直接除，而是**三个上限取最大**：
```
shards = max( 存储驱动, 单查询延迟驱动, 写入驱动 )
```
1. **存储驱动**：`shards = ceil(总压缩后数据量 / 单 shard 目标容量)`。单 shard 目标容量看查询形态：
   - 索引命中好（点查/前导列过滤，只扫少量 granule）→ 单节点可到**数十 TB**，容量只卡盘不卡查询。
   - 扫描/聚合重（大范围 GROUP BY）→ **1–4 TB** 就该考虑分片，因单查询扫描量 ∝ 单节点数据量。
   - ⚠️ 一律按**压缩后**算（CK 典型 5–10× 压缩），别拿原始量吓自己多分片。
2. **单查询延迟驱动**：扇出宽度 = shard 数；扫 N 行分 K shard → 每个扫 N/K，近似线性提速。按"这条大聚合要压到 X 秒"倒推所需并行度。
3. **写入驱动**：单节点 insert 可达几百 MB/s ~ GB/s，通常不是绑定约束。

- 总节点数 = `shards × replicas`；每台存 `总量/shards`（不是 /节点数，副本是全量拷贝）。
- 建议：先做大单节点 → 撞"存不下/扫不动"才加 shard → shard 数按存储/延迟上限取大，**起步就留够**（re-shard 比预留贵得多）。

### Replica 数 vs QPS
- **读 QPS 随副本数近似线性增长**，且读路径不碰 Keeper（Keeper 只在写/DDL 路径），扩展干净。
- 拿到线性的两个前提：
  1. **并发要分散到副本**：靠 `load_balancing`（新版默认 `random`）+ **客户端连接打散到所有节点**（前挂 LB 轮询）。否则所有连接压同一 coordinator，先撞聚合瓶颈，副本再多没用。
  2. **瓶颈在数据节点 CPU/IO**。若瓶颈在单 coordinator 聚合或单条连接，加副本不解决。
- 线性衰减/反噬拐点：**写放大反压**——副本越多，每次 insert 复制流量越大（N 份）+ 各自 merge。读多写少→扩读干净；写重→加副本反吃读能力。`QPS_max ≈ R × 单节点并发 / 单查询耗时`。
- 副本数选型：

| 副本数 | 容忍故障 | 场景 |
|---|---|---|
| 1 | 0 | 纯 dev / 可重灌 |
| 2 | 1 | 最低 HA（⚠️ 滚动重启时临时只剩 1 份） |
| **3** | 2 | **生产甜点**（滚动重启仍有 2 份冗余，HA/成本平衡） |
| 4 | 3 | 极高可用 or 超高读并发（通常为读吞吐加，纯 HA 过度） |

- **决策逻辑**：副本数由 (1) 要扛几台同时故障（含滚动运维期）+ (2) 读并发驱动。**纯 HA 一般 3 封顶够用**；再往上基本是拿副本做读扩展。别为"更安全"无脑堆副本，每份都是等比存储成本 + 写放大。

---

## 4. 机型：ARM（Graviton）还是 x86？→ 默认 ARM

CK 是少数在 ARM 上几乎无脑赢的负载：
1. **性价比**：同规格 Graviton 便宜 ~20%，而 CK 扫描/聚合是内存带宽 + 整数/SIMD 密集，Graviton（尤其 r8g/i8g 的 Neoverse V2）带宽和每核吞吐能打，**每 TB 扫描成本**通常明显低于 x86。
2. **CK 官方一等公民**：原生 aarch64 + NEON/SVE 向量化路径，Altinity 推荐平台。调过，不是"能跑"。
3. **能效/密度**：大集群电费、机架密度占优。

**留在 x86 的少数例外：**
- 依赖**只有 x86 的二进制**：CK 的 executable UDF/dictionary、某些 JDBC bridge、第三方扩展镜像无 arm64。
- 极致单核峰值频率场景（少见，CK 吃并行不吃单核）。
- 团队镜像/CI 全 x86，短期不想碰多架构构建。

**结论：无硬性 x86 依赖 → 无脑 Graviton。**

---

## 5. 存储：EBS gp3 vs 本地 NVMe（instance store）

| 维度 | EBS gp3 | 本地 NVMe（im4gn / i4g / i8g；x86 对照 i4i/i7ie） |
|---|---|---|
| IO 性能 | 网络块存储，够用 | **显著更强**（直连 PCIe，低延迟、高 IOPS） |
| 数据持久性 | ✅ 卷独立，节点挂了重挂即用 | ❌ 节点 stop/terminate/故障/底层迁移 = 盘上数据**永久丢**，不可找回 |
| 节点故障恢复 | **秒级重挂**旧卷 | **分钟~小时级**从副本重灌全量 |
| 恢复对副本依赖 | 弱（卷还在） | **强，唯一手段**，源副本必须活 |
| 跨 AZ / 反亲和 | 建议 | **强制**，否则可能全丢 |
| 成本 | 存储单独计费 | 盘含在实例价，常更划算 |

**为什么本地 NVMe 对 CK 常是升级**：merge（后台不停合并 part）、大范围扫描是重 IO；本地盘低延迟 + 高 IOPS 直接喂饱，且省掉 EBS 网络带宽这条隐性瓶颈（大机型上 EBS 吞吐和网络额度耦合）。

**根本取舍：数据不持久。** instance store 与实例生死绑定，设计上就会丢。

- **起步/求稳 → gp3**：恢复快、心智负担低。3 副本 + gp3 是最省事的生产形态。
- **IO 撞墙（merge 堆积、扫描被盘拖慢）→ im4gn/i8g**，前置条件焊死：3 副本 + 严格跨 3 AZ + hostname 反亲和 + `karpenter.sh/do-not-disrupt` 防主动搬迁。
- **两头兼顾 → 本地 NVMe 热数据 + S3 tiered/备份冷数据**（见 §7）。

**⚠️ 只有在 §7 的 S3-as-SoT 前提下，本地 NVMe 的"会丢"才从缺点变成"无所谓"——两个话题在这里合流。**

---

## 6. 让 pod 吃满整台 EC2（一 node 一 pod）

**一台 EC2 = 一个 CK pod 是推荐形态，不是将就。** CK 是"贪婪型"：吃满 CPU 并行、要大块 RAM 聚合、极度依赖 OS page cache 读压缩块。与别的 pod 挤会互相踩（CPU 争抢、page cache 被驱逐、NUMA 跨节点），低且不可预测。

### 关键误区：按 allocatable 填，不是按 capacity 填
```
EC2 capacity（如 m6g.8xlarge = 32 vCPU / 128 GiB）
  − kube-reserved + system-reserved（kubelet/containerd/OS）
  − eviction 阈值（默认 ~100Mi）
  = Allocatable                      ← 调度器实际能分的上限
  − DaemonSet 占用（CNI/kube-proxy/EBS CSI/日志监控 agent）
  = CK pod 真正能拿到的
```
- **别硬编码 `cpu:32 / memory:128Gi`** → pod 永远 Pending。
- 做法：`kubectl describe node` 看 **Allocatable**，减 DaemonSet requests，CK request 设到**略低于净值**。（m6g.8xlarge 上 allocatable 内存 ~122Gi、CPU ~31.x）

### 四个手柄
1. **独占节点**（taint + nodeSelector）：给 CK NodePool 打 taint，pod 加 toleration + nodeSelector。除 DaemonSet 外无人来抢。
2. **一 node 一 pod**（`podAntiAffinity` + `topologyKey: kubernetes.io/hostname`，`required` 硬约束）：防两个副本挤同机（挤了 = 副本不冗余）。
3. **CPU：request 拉高，不设 limit**。CPU limit = CFS quota，高峰 throttle 掐并行；独占节点无竞争，设 limit 有害。`requests.cpu` 设到接近 allocatable，**不设 cpu limit**。CK cgroup-aware：无 limit 时按整机核数开线程池正好吃满；设了 limit 新版会缩线程池 + 挨 throttle。代价 QoS 变 Burstable（独占节点无所谓）。
4. **内存：request == limit，但留 page cache 余量**。`requests.memory == limits.memory`（内存要 Guaranteed 避免驱逐）；但**别顶满 allocatable**——CK 读压缩数据走 OS page cache，cgroup v2 里 file page 也算进容器内存。配 CK 侧 `max_server_memory_usage_to_ram_ratio: 0.9`，查询工作内存封顶 cgroup 的 90%，留 10% 给 page cache + 开销（CK 自读 cgroup limit，ratio 相对容器 limit 生效）。

### YAML 骨架（Altinity CHI + Karpenter，以 m6g.8xlarge 示例）
```yaml
# —— ClickHouseInstallation ——
spec:
  configuration:
    clusters:
      - name: default
        layout: { shardsCount: 1, replicasCount: 3 }   # 1 shard × 3 副本
    settings:
      max_server_memory_usage_to_ram_ratio: "0.9"       # 留 page cache
  defaults:
    templates: { podTemplate: ck, dataVolumeClaimTemplate: data }
  templates:
    podTemplates:
      - name: ck
        spec:
          tolerations:                                   # ① 独占节点
            - { key: dedicated, value: clickhouse, operator: Equal, effect: NoSchedule }
          nodeSelector: { workload: clickhouse }
          affinity:
            podAntiAffinity:                             # ② 一 node 一 pod（硬）
              requiredDuringSchedulingIgnoredDuringExecution:
                - topologyKey: kubernetes.io/hostname
                  labelSelector:
                    matchLabels: { clickhouse.altinity.com/chi: ck }
          containers:
            - name: clickhouse
              resources:
                requests: { cpu: "30", memory: 112Gi }   # ← 略低于 allocatable（~31/~122）
                limits:   { memory: 112Gi }              # ← 只限内存，不限 CPU
    volumeClaimTemplates:
      - name: data
        spec:
          storageClassName: gp3
          accessModes: [ReadWriteOnce]
          resources: { requests: { storage: 500Gi } }
```
```yaml
# —— Karpenter NodePool ——
spec:
  template:
    metadata: { labels: { workload: clickhouse } }
    spec:
      taints:
        - { key: dedicated, value: clickhouse, effect: NoSchedule }
      requirements:
        - { key: karpenter.k8s.aws/instance-family, operator: In, values: ["m6g","r7g"] }
        - { key: karpenter.k8s.aws/instance-size,   operator: In, values: ["8xlarge"] }  # 锁大小防降级
        - { key: kubernetes.io/arch,                 operator: In, values: ["arm64"] }
        - { key: topology.kubernetes.io/zone,        operator: In, values: ["us-east-1a","us-east-1b","us-east-1c"] }
  disruption:
    consolidationPolicy: WhenEmpty        # ⚠️ 有状态 DB 别用 WhenEmptyOrUnderutilized
```

### Karpenter / EBS 坑点
- **锁 `instance-size`**，否则 Karpenter 按 requests 算可能挑更小机型，或（request 太贴 allocatable 时）反跳更大机型。
- **`consolidationPolicy` 别用 `WhenEmptyOrUnderutilized`**，或给 pod 加 `karpenter.sh/do-not-disrupt: "true"`——DB pod 被主动整理重排是灾难。
- **EBS 是 AZ 绑定**：pod 重建时 Karpenter 必须在 PVC 所在 AZ 起新机；NodePool zone requirement 要覆盖，否则重建卡住。

### 节点级调优（pod 定义之外，CK 官方硬建议）
- THP 设 `madvise`；`nofile` 调到 500000+；关 swap。走 podTemplate 的 initContainer/securityContext，或用 tuning DaemonSet 打到节点。

---

## 7. 核心架构主张：湖仓/S3 当 SoT，CK 当可重建的派生 serving 层

**这是把前面所有取舍串起来的关键定位。**

```
   ┌─────────────── Source of Truth ───────────────┐
   │  Lakehouse on S3（Iceberg/Delta/Hudi/Parquet） │  ← 权威、持久、全量、廉价
   │  + Glue Catalog                                │
   └───────────────────────┬────────────────────────┘
                 ELT / 定时同步 / 增量摄入
                            ▼
   ┌────────────────────────────────────────────────┐
   │  ClickHouse = 派生的、可重建的查询加速层         │  ← 热数据、MergeTree 排好序、喂 BI
   │  1 shard × N replica，本地 NVMe，吃满大机        │
   └────────────────────────────────────────────────┘
```

**心智转变：CK 从"有状态数据库"降级成"派生态物化缓存"。数据的家在 S3，CK 只是为查询优化过的一份拷贝。** 一旦接受这个定位，取舍全顺：
- ✅ 本地 NVMe 的"会丢"不再是问题——丢了本来就能从 S3 重灌（§5 与此合流）。
- ✅ DDL 走 CICD 秒级重建 schema（DDL 是瞬时的）。`ORDER BY`/partition/codec/TTL 这些调优精华当代码版本化。
- ✅ **两级恢复**：部分故障用副本兜（快路径），全挂用 S3 pipeline 兜（慢兜底）。
- ✅ 副本数可按"读 QPS"定，不用按"怕丢数据"定（durability 交给 S3）。
- ✅ 甚至可做"按需起集群"：高峰起、闲时缩，数据反正在 S3。

### 从湖仓导入 CK 的摄入方式（按 SoT 形态选）
| SoT 形态 | 推荐摄入 | 场景 |
|---|---|---|
| 裸 Parquet 落 S3 前缀 | `INSERT INTO ck SELECT * FROM s3(...)` | 批量回填 / 一次性 backfill |
| 持续新文件落 S3 | **`S3Queue` 引擎**（原生自动消费，类 Kafka 位点） | 准实时微批 |
| 开放表格式 Iceberg/Delta/Hudi | `iceberg()`/`deltaLake()`/`hudi()` 表函数或引擎，直连 Glue/REST catalog | SoT 已是 lakehouse 表 |
| 想声明式定时拉 | **Refreshable Materialized View**（定时从 s3()/iceberg() 刷新） | 让"从湖同步"变成 DDL 声明，不用外部 orchestrator |
| 上游是流 | Kafka/MSK 引擎 | 流式 SoT |

⚠️ 成熟度：`S3Queue`、refreshable MV、Iceberg **写** 都是近一两年才转稳；读侧很稳，写/exactly-once 语义按集群版本查 changelog。

### 两种"存算分离"要分清（我们选第一种）
- **(A) ELT 拷贝**（本方案）：湖是 SoT，CK 本地快盘持一份 MergeTree 拷贝。恢复 = 重灌。查询快、湖权威、运维简单。**轻量 BI serving 层 → 几乎总是更优。**
- **(B) CK 原生 S3 disk + zero-copy**：数据直接住 S3，节点纯 compute+cache，恢复 = 重新指向、无需重灌。弹性极致，但冷读有 S3 延迟、运维更重。

### 落地必须做对的 4 件事
1. **幂等 / 去重**（重放命根子）：
   - 按分区重放：`PARTITION BY toYYYYMMDD(...)`，恢复时 `DROP PARTITION` 再干净重插，别全表重来。
   - block 级去重（`insert_deduplicate`，Keeper 记最近插入块 hash）挡重复相同块。
   - 行级 upsert → `ReplacingMergeTree`。
   - 记 watermark / high-water-mark，知道哪些已入、从哪重放，别每次全量。
2. **增量非全量**：节点故障恢复不该重放全部历史——副本兜近期热数据 + S3 只重放受影响/近期分区。全量重灌只留给"整 shard 所有副本同时没了"的真灾难。分区设计决定能只重放一小片。
3. **Schema 漂移要管**：Iceberg 的 schema evolution **不自动传导** CK（CK 是下游拷贝）；列增减、类型变更要在 CICD 显式映射。`ORDER BY`/codec 锁版本库，重建才字节级一致。
4. **一致性 lag 写进 SLA**：CK 是湖下游派生 → 最终一致；BI 看到的是"上次同步时点"。定位允许，但要显式告知新鲜度 = X 分钟，别让人当实时。

---

## 8. 恢复对比：副本 fetch vs S3 重灌

**差距根源不是数据量，是"干的活不同"：**
```
副本间恢复（fetch）     : 复制【已建好的 MergeTree part】—— 排好序/压好缩/建好索引的字节
                        → 网络文件拷贝，CPU 几乎不干活（interserver 9009 端口，原样推送，不解压/不重排）
S3 重灌恢复（re-ingest）: 读 Parquet →【重新排序 + 重新压缩 + 重建稀疏索引 + merge 碎 part】
                        → CPU/IO 密集的全量重建，part 是现造的
```

| | 副本 fetch | S3 重灌 |
|---|---|---|
| 处理对象 | 现成压缩 part | 读 Parquet + 重建成 part |
| 瓶颈 | 网络带宽 | CPU（排序+压缩）+ S3 读带宽 |
| 有效速率（粗略） | ~500 MB/s – GB/s 网络级 | ~100–300 MB/s 输出级（受核数限制） |
| 500 GiB 估时 | **~10–20 分钟** | **~40 分钟 – 2 小时** |
| 数量级 | 基准 | **慢约一个数量级** |

- ⚠️ 数字是数量级估算（narrative 用途，非承诺值）；实际取决于并行度、网络、S3 带宽、part 碎片、机型算力。
- **RTO 拆解（S3 全挂恢复）**：Karpenter 起节点（几分钟）+ DDL 建表（秒级 ✅）+ **从 S3 读+重建 MergeTree（长杆，几十分钟~小时级）**。别把 S3 恢复当"快速切换"，它是"可接受的 DR RTO"。

### 副本恢复期间的影响（校准"只减 QPS"的说法）
- ✅ **读 QPS 上限下降**：3→2 在服务，读容量掉 ~1/3。方向对。
- ⚠️ **但不干净——源副本双重打工**：当源的那个副本既服务查询又往外推 part，它自己的查询延迟被拖慢。整体下滑比"少一台"更明显。
- ✅ **不受影响**：写入不中断（新写入排队一起追）；查询正确性不受影响（未追平副本不被路由，`max_replica_delay_for_distributed_queries` 控制）；无写停顿/脑裂/不一致。
- ➕ **冗余度临时降级**：3→2，窗口内再挂一台只剩 1；恢复越久裸奔窗口越长。这是可用性风险，也是"恢复要快"的真正理由。

### 调节旋钮：恢复速度 ↔ QPS 保护
- `max_replicated_fetches_network_bandwidth_for_server`：给恢复流量设带宽上限，留带宽给查询（牺牲恢复速度换 QPS 稳）。
- `background_fetches_pool_size`：并行 fetch 线程数，调大加速恢复（但更抢源副本 IO）。
- 用法：高峰出故障→限流保 QPS 让恢复慢点；低峰→放开带宽尽快脱离 2 副本裸奔。（S3 重灌那条路有对应旋钮：摄入并发 vs 查询资源，但副本这条更精细常用。）

---

## 9. 待核查 / 版本相关（别当定论，按实际集群确认）

- `S3Queue` / refreshable MV / Iceberg 写 的成熟度与 exactly-once 语义 —— 锁版本查 changelog。
- `parallel_replicas` 的稳定性与开启方式 —— 近版本趋稳。
- reference stack 的实际 `clickhouse-cluster.yaml`：`internal_replication` 是否 `true`（用 Replicated 引擎时**必须** true，否则 Distributed 写 + 引擎复制 = 数据双写；Operator 默认给对，但自建集群头号坑）；AZ topology spread / anti-affinity 实际值；`<zookeeper>` 段指向。
- allocatable 具体值随 EKS 版本 / AMI / DaemonSet 变，部署前实测 `kubectl describe node`。

---

## 10. 一句话总纲

**S3/湖仓当 SoT + CK 当可重建的物化 serving 层；1 shard × 3 replica 大 Graviton 节点起手，一 node 一 pod 吃满整机（request≈allocatable、CPU 不设 limit、内存 request==limit + ratio 0.9）；IO 撞墙上本地 NVMe（靠 S3 兜底 durability）；DDL as code 秒级建表；两级恢复——副本 fetch 走快路径（分钟级、拷现成 part），S3 重灌走慢兜底（小时级 DR、重建 MergeTree）。撞到"单查询只用一台算力 / 全量塞不下一台"才引入分片，之前先用 parallel_replicas 顶。**
