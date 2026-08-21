# ClickHouse on EKS —— 生产最佳实践笔记（2026-07）

**中文** · [English](./notes-ck-on-eks-best-practices-2026.en.md)

> 背景：以 awslabs data-on-eks 的 clickhouse-on-eks reference stack（Altinity Operator + Keeper + Karpenter + ArgoCD，示例 3×3）为起点，结合本项目的数据角色和运维边界形成部署建议。
> 参考页：https://awslabs.github.io/data-on-eks/docs/datastacks/databases/clickhouse-on-eks

---

## 0. 适用边界

本文针对一个具体的数据角色：上游数据湖仓承接唯一权威 Source of Truth,CK 作为其下游派生、最终一致、可重建的 OLAP / BI serving 加速层。

以下建议仅在这一数据角色下成立。出现下列情况时,需要重新评估存储、分片和副本策略：

- CK 必须是**主存储 / 唯一 SoT**（没有上游湖仓兜底）→ durability 要求陡增，本地 NVMe 那套不成立，得回到 EBS + 备份为主。
- **极高吞吐实时摄入**（如大规模 Kafka 直灌、写重于读）→ 写放大成为主约束，副本策略、分片策略都要重估。
- **超大规模、单查询要跨很多机器扇出** → 必须真正分片，1-shard scale-up 顶不住。

因此,本文讨论的是"CK 作为湖仓派生 serving 层在 EKS 上的部署建议",不适用于所有 ClickHouse on EKS 场景。

---

## 1. 拓扑基础

### shard = 按行水平切分，不是按列
- 每个 shard 存全表的一个**行子集**，schema 相同；拼起来才是全表。
- CK 是列存，但"列存"是**单节点内**磁盘按列组织；"分片"是**跨节点**按行切。两个正交维度。**不存在列级分片。**
- 分到哪个 shard 由 sharding key 的 hash 决定（reference 用 `cityHash64(UserID)`）。近似均衡，**不保证严格等分**——key 倾斜会导致某 shard 偏胖。
- shard 数最小是 **1**（不存在 0）。任意正整数都合法（2/4/7…）。

### replica = 同一 shard 的完整数据拷贝，multi-master，无主从
- **模型说明**：CK 的 ReplicatedMergeTree 是**多主对等（masterless）**，不是 MySQL/PG/Redis 的 primary-replica 模型。
  - 没有"主副本"角色，**没有主从选举、没有故障 promotion**。
  - 每个副本都能读能写；挂一个，其余照常，重启后自己去 Keeper 对账追平。
  - （历史包袱：老版本有个 "leader" 只管调度 merge，与读写无关；20.5 后多 leader，该瓶颈基本消失。别用"主/从"套 CK。）
- 副本数**无奇偶要求**（2/4 都行）。⚠️ 别和 **Keeper** 混——Keeper 是 Raft，要奇数（3/5）凑 quorum；**数据副本不走 quorum**（默认异步复制）。

### 两个维度分别解决的问题
```
想让"一个查询"更快 / 装更多数据  →  加 SHARD（横向切分，按行）
想扛更多"并发查询" / 挂机不停服  →  加 REPLICA（冗余，多主对等）
```

### 与 Kafka/MSK 的类比
```
Kafka partition  ≈  CK SHARD    ← 并行/切分单元
Kafka replica    ≈  CK REPLICA  ← 冗余单元
```
- 并行度来自 shard，不来自 replica（同 Kafka：并行来自 partition 数）。
- **差异**：Kafka follower 默认不对外服务（KIP-392 后才有 follower read）；**CK 副本全部可读**。

---

## 2. 推荐起手式：1 shard × 3 replica + 大节点（scale-up 优先）

本项目默认先垂直扩容单节点,仅在容量或单查询算力达到上限后引入分片,原因如下：
- 单节点 CK 可以承载压缩后的 TB 级数据,实际容量取决于查询形态和存储配置。
- **re-sharding 操作成本较高**：CK 无自动 rebalance,增加 shard 后历史数据不会自动迁移,需要手动执行 `INSERT SELECT` 或使用 `clickhouse-copier`。

所以推荐默认形态：**不分片（shardsCount: 1）+ 3 副本 + 每副本独占一台大 Graviton，跨 3 AZ。**

```
        replica r1        replica r2        replica r3
       ┌──────────┐      ┌──────────┐      ┌──────────┐
       │ 大 pod   │ ≈≈≈  │ 大 pod   │ ≈≈≈  │ 大 pod   │   全量数据 × 3 份完整拷贝
       │  AZ-a    │      │  AZ-b    │      │  AZ-c    │
       └──────────┘      └──────────┘      └──────────┘
   1 个 shard = 每节点都有全表，无横向切分；每 pod 独占一台 EC2
```

**采用该默认拓扑的原因：**
- ✅ 初始阶段无需执行 re-sharding。
- ✅ 无跨 shard 扇出,不产生 coordinator 的多 shard 聚合开销。
- ✅ HA + 读扩展都到位：挂 1 台仍有 2 份；读 QPS 近似 3×。
- ✅ 扩容路径明确：读吞吐不足时增加副本,单节点资源不足时更换更大机型,两者均不改变数据分片。

**两个拓扑约束：**
1. **使用 `Replicated` 引擎时需要 Keeper**。复制协调与 shard 数无关,因此 1×3 仍需 3 节点 Keeper ensemble。
2. **1 shard 场景通常不需要 Distributed 表**。每个副本都保存全量数据,客户端可通过 LB 轮询 3 个 Pod,直接查询 ReplicatedMergeTree 本地表。Distributed 表会增加一次不必要的转发。

**引入 shard 的条件：**
1. 单节点存不下全量（压缩后超单机盘 / 超机型可挂最大 EBS/NVMe）。
2. **单条大聚合太慢**——1 shard 下一个查询只能吃一台的算力，副本不加速单查询。扫大半表的重聚合会被单机 CPU 卡死。（最常见的隐性上限）
3. 写入吞吐超单节点上限（较少见）。

**分片前可评估 `parallel_replicas`**。开启后,一个查询可以调用同 shard 的多个副本并行扫描数据,提高单查询并行度。在 1-shard 拓扑中,它可用于缓解单查询算力限制,但收益取决于查询类型,并会引入协调开销。启用前应按固定版本验证,并检查 changelog。

---

## 3. Sizing 量化

### Shard 数 vs 数据量
Shard 数需要同时考虑三个约束：
```
shards = max( 存储驱动, 单查询延迟驱动, 写入驱动 )
```
1. **存储驱动**：`shards = ceil(总压缩后数据量 / 单 shard 目标容量)`。单 shard 目标容量看查询形态：
   - 索引命中好（点查/前导列过滤，只扫少量 granule）→ 单节点可到**数十 TB**，容量只卡盘不卡查询。
   - 扫描/聚合重（大范围 GROUP BY）→ **1–4 TB** 就该考虑分片，因单查询扫描量 ∝ 单节点数据量。
   - ⚠️ 按**压缩后**的数据量计算（CK 典型压缩比为 5–10×）,避免根据原始数据量过度分片。
2. **单查询延迟驱动**：扇出宽度 = shard 数；扫 N 行分 K shard → 每个扫 N/K，近似线性提速。按"这条大聚合要压到 X 秒"倒推所需并行度。
3. **写入驱动**：单节点 insert 可达几百 MB/s ~ GB/s，通常不是绑定约束。

- 总节点数 = `shards × replicas`；每台存 `总量/shards`（不是 /节点数，副本是全量拷贝）。
- 建议：先垂直扩容单节点,达到存储或扫描上限后再增加 shard。Shard 数取满足存储与延迟约束的较大值,并预留容量,因为 re-sharding 的操作成本通常高于容量预留。

### Replica 数 vs QPS
- **读 QPS 可随副本数近似线性增长**，且读路径不经过 Keeper（Keeper 用于写入和 DDL 路径）。
- 拿到线性的两个前提：
  1. **并发要分散到副本**：靠 `load_balancing`（新版默认 `random`）+ **客户端连接打散到所有节点**（前挂 LB 轮询）。否则所有连接压同一 coordinator，先撞聚合瓶颈，副本再多没用。
  2. **瓶颈在数据节点 CPU/IO**。若瓶颈在单 coordinator 聚合或单条连接，加副本不解决。
- 线性衰减/反噬拐点：**写放大反压**——副本越多，每次 insert 复制流量越大（N 份）+ 各自 merge。读多写少→扩读干净；写重→加副本反吃读能力。`QPS_max ≈ R × 单节点并发 / 单查询耗时`。
- 副本数选型：

| 副本数 | 容忍故障 | 场景 |
|---|---|---|
| 1 | 0 | 纯 dev / 可重灌 |
| 2 | 1 | 最低 HA（⚠️ 滚动重启时临时只剩 1 份） |
| **3** | 2 | 常用生产配置（滚动重启时仍有 2 份冗余） |
| 4 | 3 | 极高可用 or 超高读并发（通常为读吞吐加，纯 HA 过度） |

- **决策逻辑**：副本数由 (1) 需要容忍的同时故障数（含滚动运维期）和 (2) 读并发共同决定。仅考虑 HA 时通常使用 3 副本;更多副本主要用于读扩展,同时会等比例增加存储成本和写放大。

---

## 4. 机型：ARM（Graviton）还是 x86？→ 默认 ARM

在没有架构依赖时,本项目默认选择 ARM：
1. **性价比**：同规格 Graviton 价格约低 20%。CK 扫描和聚合依赖内存带宽及整数/SIMD 性能,Graviton（尤其 r8g/i8g 的 Neoverse V2）可降低**每 TB 扫描成本**,但具体差异仍需按目标查询测试。
2. **软件支持**：ClickHouse 提供原生 aarch64 和 NEON/SVE 向量化路径,Altinity 也将其列为推荐平台。
3. **能效/密度**：大集群电费、机架密度占优。

**留在 x86 的少数例外：**
- 依赖**只有 x86 的二进制**：CK 的 executable UDF/dictionary、某些 JDBC bridge、第三方扩展镜像无 arm64。
- 极致单核峰值频率场景（少见，CK 吃并行不吃单核）。
- 团队镜像/CI 全 x86，短期不想碰多架构构建。

**结论：** 没有 x86-only 二进制或工具链约束时,优先评估 Graviton;最终选择应以目标负载测试为依据。

---

## 5. 存储：EBS gp3 vs 本地 NVMe（instance store）

| 维度 | EBS gp3 | 本地 NVMe（im4gn / i4g / i8g；x86 对照 i4i/i7ie） |
|---|---|---|
| IO 性能 | 网络块存储，够用 | **显著更强**（直连 PCIe，低延迟、高 IOPS） |
| 数据持久性 | ✅ 卷独立，节点挂了重挂即用 | ❌ 节点 stop/terminate/故障/底层迁移 = 盘上数据**永久丢**，不可找回 |
| 节点故障恢复 | **秒级重挂**旧卷 | **分钟~小时级**从副本重灌全量 |
| 恢复对副本依赖 | 弱（卷还在） | **强，唯一手段**，源副本必须活 |
| 跨 AZ / 反亲和 | 建议 | **强制**，否则可能全丢 |
| 成本 | 存储单独计费 | 盘含在实例价，需按实例与卷的总月成本比较 |

**本地 NVMe 的性能收益**：merge 和大范围扫描属于 I/O 密集型操作;本地盘的低延迟和高 IOPS 可以减少存储等待,也不受实例 EBS 通道限制。收益大小取决于工作集是否进入 page cache 以及负载是否持续受存储限制。

**根本取舍：数据不持久。** instance store 与实例生死绑定，设计上就会丢。

- **默认选择 gp3**：节点替换可重挂原卷,恢复流程较短。3 副本 + gp3 适用于优先降低运维复杂度的场景。
- **存储成为持续瓶颈时评估 im4gn/i8g**：前置条件包括 3 副本、严格跨 3 AZ、hostname 反亲和,以及使用 `karpenter.sh/do-not-disrupt` 防止主动搬迁。
- **分层方案**：本地 NVMe 保存热数据,S3 用于分层或备份冷数据（见 §7）。

**⚠️ 只有在 §7 的上游湖仓 SoT 可重放前提下，本地 NVMe 的数据丢失才不会造成权威数据丢失;但 local PV 仍需人工释放和重建,不是"无所谓"。**

---

## 6. 让 pod 吃满整台 EC2（一 node 一 pod）

本项目采用**一台 EC2 运行一个 CK Pod**。ClickHouse 会使用大量 CPU 并行度、聚合内存和 OS page cache;与其他工作负载共置会引入 CPU 争用、page cache 驱逐和 NUMA 跨节点访问,使性能波动增大。

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
- **`consolidationPolicy` 不使用 `WhenEmptyOrUnderutilized`**,或为 Pod 添加 `karpenter.sh/do-not-disrupt: "true"`。主动重排有状态数据库 Pod 会触发不必要的恢复过程。
- **EBS 是 AZ 绑定**：pod 重建时 Karpenter 必须在 PVC 所在 AZ 起新机；NodePool zone requirement 要覆盖，否则重建卡住。

### 节点级调优（pod 定义之外，CK 官方硬建议）
- THP 设 `madvise`；`nofile` 调到 500000+；关 swap。走 podTemplate 的 initContainer/securityContext，或用 tuning DaemonSet 打到节点。

---

## 7. 数据角色：上游湖仓是唯一 SoT，CK 是可重建的派生 serving 层

以下数据角色是前述存储和恢复策略的共同前提。

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

CK 不承担权威数据库角色,而是湖仓数据的派生物化加速层。上游湖仓（通常基于 S3）保存权威数据,CK 保存针对查询优化的副本。仓库内 clickhouse-backup 的 S3 bucket 是辅助恢复点,不是湖仓。在此前提下：
- ✅ 本地 NVMe 丢失不会造成权威数据丢失——释放失效 local PV 后可从健康副本恢复,必要时从湖仓重灌（§5 与此合流）。
- ✅ DDL 走 CICD 秒级重建 schema（DDL 是瞬时的）。`ORDER BY`/partition/codec/TTL 这些调优精华当代码版本化。
- ✅ **两级恢复**：部分故障从健康副本 fetch（快路径），全挂从上游湖仓重灌（权威慢路径）；ClickHouse S3 备份用于缩短 RTO。
- ✅ 副本数可按"读 QPS + 在线可用性"定,权威 durability 由上游湖仓承担。
- ✅ 可以评估按需运行集群,但缩容策略必须考虑本地 NVMe 数据丢失、重载时间和恢复成本。

### 从湖仓导入 CK 的摄入方式（按 SoT 形态选）
| SoT 形态 | 推荐摄入 | 场景 |
|---|---|---|
| 裸 Parquet 落 S3 前缀 | `INSERT INTO ck SELECT * FROM s3(...)` | 批量回填 / 一次性 backfill |
| 持续新文件落 S3 | **`S3Queue` 引擎**（原生自动消费，类 Kafka 位点） | 准实时微批 |
| 开放表格式 Iceberg/Delta/Hudi | `iceberg()`/`deltaLake()`/`hudi()` 表函数或引擎，直连 Glue/REST catalog | SoT 已是 lakehouse 表 |
| 想声明式定时拉 | **Refreshable Materialized View**（定时从 s3()/iceberg() 刷新） | 让"从湖同步"变成 DDL 声明，不用外部 orchestrator |
| 上游是流 | Kafka/MSK 引擎 | 流式派生摄入;长期权威历史仍落湖仓 |

⚠️ 成熟度：`S3Queue`、refreshable MV、Iceberg **写** 都是近一两年才转稳；读侧很稳，写/exactly-once 语义按集群版本查 changelog。

### 两种"存算分离"要分清（我们选第一种）
- **(A) ELT 拷贝**（本方案）：湖是 SoT,CK 本地快盘保存 MergeTree 副本,故障后通过重载恢复。适用于查询延迟优先且可接受重载 RTO 的 BI serving 场景。
- **(B) CK 原生 S3 disk + zero-copy**：数据直接住 S3，节点纯 compute+cache，恢复 = 重新指向、无需重灌。弹性极致，但冷读有 S3 延迟、运维更重。

### 落地必须做对的 4 件事
1. **幂等 / 去重**（保证重放结果一致）：
   - 按分区重放：`PARTITION BY toYYYYMMDD(...)`，恢复时 `DROP PARTITION` 再干净重插，别全表重来。
   - block 级去重（`insert_deduplicate`，Keeper 记最近插入块 hash）挡重复相同块。
   - 行级 upsert → `ReplacingMergeTree`。
   - 记 watermark / high-water-mark，知道哪些已入、从哪重放，别每次全量。
2. **优先增量恢复**：节点故障恢复不应默认重放全部历史。副本用于恢复近期热数据,S3 只重放受影响或近期分区。仅在整个 shard 的全部副本丢失时执行全量重载;能否按小范围恢复取决于分区设计。
3. **Schema 漂移要管**：Iceberg 的 schema evolution **不自动传导** CK（CK 是下游拷贝）；列增减、类型变更要在 CICD 显式映射。`ORDER BY`/codec 锁版本库，重建才字节级一致。
4. **一致性 lag 写进 SLA**：CK 是湖下游派生 → 最终一致；BI 看到的是"上次同步时点"。定位允许，但要显式告知新鲜度 = X 分钟，别让人当实时。

---

## 8. 恢复对比：副本 fetch vs S3 重灌

两种恢复路径处理的数据形态和计算步骤不同：
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
- **RTO 拆解（S3 全量恢复）**：Karpenter 启动节点（几分钟）+ DDL 建表（秒级）+ **从 S3 读取并重建 MergeTree（通常为几十分钟到小时级）**。S3 重载属于 DR 恢复路径,不是快速故障切换。

### 副本恢复期间的影响（校准"只减 QPS"的说法）
- ✅ **读 QPS 上限下降**：3→2 在服务，读容量掉 ~1/3。方向对。
- ⚠️ **源副本同时承担查询和恢复流量**：源副本在服务查询的同时传输 part,查询延迟可能上升,总体容量下降可能超过单纯减少一个副本的影响。
- ✅ **不受影响**：写入不中断（新写入排队一起追）；查询正确性不受影响（未追平副本不被路由，`max_replica_delay_for_distributed_queries` 控制）；无写停顿/脑裂/不一致。
- ➕ **冗余度临时降级**：3→2 后,恢复窗口内再次丢失一个副本将只剩 1 个副本。缩短恢复时间可以减少这一风险窗口。

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

## 10. 设计摘要

上游湖仓承担唯一 SoT,CK 作为可重建的物化 serving 层。默认拓扑为大规格 Graviton 节点上的 1 shard × 3 replicas,每个节点运行一个 Pod（request 接近 allocatable、不设 CPU limit、内存 request 等于 limit,并设置 ratio 0.9）。存储持续成为瓶颈时评估本地 NVMe;DDL 由代码管理。部分故障优先从健康副本 fetch,全部副本丢失时从湖仓重载,ClickHouse S3 备份用于缩短 RTO。当单查询算力或单节点容量达到上限时再引入分片,此前可按查询验证 `parallel_replicas`。
