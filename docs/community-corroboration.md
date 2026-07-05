# 社区与官方对本方案设计主张的印证

> 调研日期:2026-07-05。目的:检验本方案的五条核心设计主张是否只是"一家之言",还是有社区/官方实践支撑。
> 方法:检索 GitHub、公司工程博客、会议 talk、Hacker News、ClickHouse/Altinity 官方内容。每条结论均带可追溯 URL;找不到印证的地方如实标注。
> 立场:诚实优先——包括标出本方案里"最有主见、非原厂默认"的选择。

---

## 五条主张的印证强度总览

| # | 设计主张 | 印证强度 | 最强出处 |
|---|---|---|---|
| 1 | 一分片占满一台大机、scale-up first、shard last | **强(原厂自己就这么说)** | ClickHouse "at Scale" |
| 2 | 在 EKS / Kubernetes 上跑生产 ClickHouse | **强** | ClickHouse LogHouse(19 PiB,跑在 K8s) |
| 3 | 大内存 / 一 Pod 一节点 / 不设 CPU limit / page-cache 感知 | **模型强,完整组合需自行组装** | Altinity "8 tricks" + oneuptime + Altinity 缓存指南 |
| 4 | 本地 NVMe 代替 EBS,靠副本兜 durability | **实践强,但非原厂默认** | mrkrbrts.com;Altinity KB EC2 Storage |
| 5 | ClickHouse 当可重建 serving 层,湖仓/S3 当真相源 | **强,已主流化** | ClickHouse "data lakehouse" Pattern 4;Tinybird |

---

## 逐条印证

### 主张 1 —— 一分片占满大机 / scale-up first, shard last
**印证:强。这几乎是 ClickHouse 官方反复强调的立场。**

- ClickHouse "ClickHouse at Scale" 官方视频 —— https://www.youtube.com/watch?v=vBjCJtw_Ei0 —— 原话:"scale up is preferred to scale out until the scale up cost becomes more than linear",且"sharding should only be considered if there's the perspective of data volume or data processing speed to exceed the capacity of a single server in the near future"。**与本主张最贴合的原厂表述。**
- ClickHouse 官方文档 Table shards and replicas —— https://clickhouse.com/docs/shards —— 把分片定位为"数据太大装不下单机"或"单机太慢"时的最后手段,而非默认。
- Altinity webinar "Deep Dive on ClickHouse Sharding and Replication" —— https://altinity.com/webinarspage/deep-dive-on-clickhouse-sharding-and-replication —— 先讲单节点垂直扩容,分片作为更难的后续步骤;并介绍 parallel_replicas 作为"实验性动态分片"来推迟物理分片。
- Goutham Veeramachaneni, "Notes on ClickHouse Scaling" —— https://www.gouthamve.dev/notes-on-clickhouse-scaling —— 实践者视角,明确点出 re-sharding 的痛点:"there's no automatic re-sharding. If you add a third shard later, only new data goes to it"。直接印证"分片无自动 rebalance、要避免"。
- ClickHouse blog on parallel_replicas —— https://clickhouse.com/blog/clickhouse-parallel-replicas —— 分片"requires resharding to add capacity, potentially hours or days of work",把 parallel replicas 定位为不分片也能加速单查询的手段。
  - 诚实 caveat:OSS shared-nothing 下 parallel replicas 仍需每个副本有完整数据副本——推迟分片,但不消除存储重复。
- HN "Ten years of ClickHouse in open source" —— https://news.ycombinator.com/item?id=48546890 —— 有评论者把数仓从 Druid+Postgres+Trino 换成"one big clickhouse node and I've never looked back"。

**反方(诚实标注)**:Instaclustr 建议相反 —— https://www.instaclustr.com/blog/clickhouse-best-practices-part-2-scaling-data-management-and-optimization —— "Plan for sharding from the start"。所以"shard-last"是主流但非唯一。

### 主张 2 —— 在 EKS / K8s 上跑生产 ClickHouse
**印证:强,含真实生产 write-up,不止 operator 文档。**

- ClickHouse "How we Built a 19 PiB Logging Platform"(LogHouse)—— https://clickhouse.com/blog/building-a-logging-platform-with-clickhouse-and-saving-millions-over-datadog —— ClickHouse 自家日志平台跑在 K8s,自研 operator 编排;最大集群 5 节点 m5d.16xlarge。真实生产。
- Altinity Terraform AWS EKS Blueprint —— https://altinity.com/blog/introducing-the-terraform-aws-eks-blueprint-for-clickhouse —— turnkey EKS + operator 参考架构;altinity.cloud 自 2020 起在 K8s 上跨 5 云运行。
- Altinity operator(GitHub)—— https://github.com/altinity/clickhouse-operator —— "manages tens of thousands of ClickHouse servers worldwide";公开采用者含 MUX、Infovista。
- 官方 ClickHouse Kubernetes Operator —— https://clickhouse.com/blog/clickhouse-kubernetes-operator —— ClickHouse Inc 自家 operator,K8s 是一等部署目标。
- Shamsul Arefin (Medium) —— https://medium.com/@shamsul.arefin/evaluating-the-performance-of-clickhouse-with-amplab-big-data-benchmark-dataset-on-kubernetes-b36e860ba027 —— EKS + Altinity operator + instance-store NVMe 实操(同时印证主张 3、4)。

### 主张 3 —— 大内存 / 一 Pod 一节点 / 不设 CPU limit / page-cache 感知
**印证:资源模型强;"不设 CPU limit + 一 Pod 一节点"的完整组合是从多源拼出来的。**

- Altinity "Eureka! 8 developer tricks for running ClickHouse on Kubernetes"(PDF)—— https://altinity.com/wp-content/uploads/2024/02/Eureka-8-developer-tricks-for-running-ClickHouse-on-Kubernetes-2024-02-27.pdf —— 确认 StatefulSet 模型"one pod per stateful set"、用 nodeSelector/实例类型标签把 Pod 钉到特定 VM、保留 PVC。直接支持一 Pod 一节点 + 专属节点定尺。
- oneuptime, "Resource Requests and Limits for ClickHouse on Kubernetes" —— https://oneuptime.com/blog/post/2026-03-31-clickhouse-resource-requests-limits-k8s/view —— 建议内存 request 设为节点 RAM 的 50–80%,且"consider omitting CPU limits for query-intensive deployments"——正是"不设 CPU limit"。
- Altinity, "Caching in ClickHouse — Definitive Guide Part 1" —— https://altinity.com/blog/caching-in-clickhouse-the-definitive-guide-part-1 —— page-cache 感知定尺:"queries typically use less than 50% of available RAM, leaving the rest for the OS page cache"。
- ClickHouse OSS usage tips —— https://clickhouse.com/docs/operations/tips —— "use a reasonable amount of RAM (128 GB or more) so the hot data subset will fit in the cache of pages"。
- ClickHouse sizing/hardware 建议 —— https://clickhouse.com/docs/guides/sizing-and-hardware-recommendations —— 真实配置示例:每副本 256 GB RAM,4–6 GB RAM/vCPU。

**诚实缺口**:没找到把"一 Pod 一节点 + 不设 CPU limit + 大内存 + page-cache"打包成单一 checklist 的权威文档。本方案是把这些散落实践系统化组装——这本身即增量价值。

### 主张 4 —— 本地 NVMe 代替 EBS,靠副本兜 durability
**印证:作为实践强;但有关于 OSS durability 语义的重要诚实 caveat。**

- Mark Roberts, "How to run a cost-efficient ClickHouse cluster with separated storage & compute" —— https://mrkrbrts.com/blog/how-to-run-a-cost-efficient-clickhouse-cluster-with-separated-storage-and-compute —— 最贴合。主张临时本地 NVMe instance-store(r7gd 家族)作为 write-through 缓存,S3 durable 兜底,跑在 EKS + Altinity operator + local-volume-provisioner,省约 40%。直面临时性:"the elephant in the room is that these disks are ephemeral... how can we make this safe?" → S3 durability。
- Altinity KB, "AWS EC2 Storage" —— https://kb.altinity.com/altinity-kb-setup-and-maintenance/aws-ec2-storage —— 重要 caveat:"ClickHouse doesn't have any native option to reuse the same data on durable network disk via several replicas. You either need to store the same data twice or build custom tooling." 即:靠副本兜 durability = 本地盘上 N 份完整拷贝。
- AWS 存储优化实例族 —— https://aws.amazon.com/ec2/instance-types/i3en —— 确认 i3/i3en/i4i/i4g 本地 NVMe 家族是专用目标;本方案 i8g/im4gn 与此家族一脉相承。
- anthonynsimon, "1-Node ClickHouse in Production" —— https://anthonynsimon.com/blog/clickhouse-deployment —— 单节点 CH 跑本地 NVMe,"on plain EC2 and on Kubernetes"。
- Severalnines, "ClickHouse Storage Architecture and Optimization" —— https://severalnines.com/blog/clickhouse-storage-architecture-and-optimization —— "SSD or NVMe disks as the preferred foundation for production"。

**诚实 caveat**:ClickHouse 官方 sizing 指南推荐 provisioned-IOPS EBS 而非 instance-store。所以"本地盘代替 EBS"是成本导向实践者的刻意取舍,不是原厂默认;且 OSS 靠副本兜 durability 意味着 N 份完整本地拷贝。

### 主张 5 —— ClickHouse 当可重建 serving 层,湖仓/S3 当真相源
**印证:强,且日益主流。已被 ClickHouse Inc 和 Tinybird 明确记录为架构模式。**

- ClickHouse Inc, "What is a data lakehouse?" —— https://clickhouse.com/resources/engineering/data-lakehouse —— Pattern 4 正是本主张:"Data is initially written to Iceberg or Delta Lake tables (the source of truth)... incrementally replicated to ClickHouse... Lakehouse maintains full history."
- Tinybird, "Apache Iceberg with ClickHouse" —— https://www.tinybird.co/blog/clickhouse-apache-iceberg-integration —— "Keep Iceberg as your source of truth... use ClickHouse (with periodic copies) as the query engine... This is the pattern Tinybird uses." 真实厂商就这么跑。
- GlassFlow —— https://www.glassflow.dev/blog/blog-data-lakes-apache-iceberg-clickhouse-data-transformation —— "Iceberg as the 'Cold' Layer / Source of Truth... ClickHouse as the 'Hot' Layer"。
- BigDataBoutique —— https://bigdataboutique.com/blog/clickhouse-and-apache-iceberg-practical-guide-to-data-lakehouse-integration —— 建议延迟敏感查询摄入原生 MergeTree,直连 Iceberg 留给 ad-hoc。
- OLake —— https://olake.io/blog/build-data-lakehouse-iceberg-clickhouse-olake —— MySQL→CDC→Iceberg(S3)→ClickHouse serving 层的端到端构建。

---

## 最接近本方案组合哲学的实践(同时命中 3 条以上)

按命中条数排序:

1. **Mark Roberts —— "cost-efficient ClickHouse with separated storage & compute"**
   https://mrkrbrts.com/blog/how-to-run-a-cost-efficient-clickhouse-cluster-with-separated-storage-and-compute
   命中 **2 + 4 + 5(隐含 3)**。EKS + Altinity operator + 临时本地 NVMe + S3 durable + 副本 HA。**最像"同一个想法"的人。** 唯一差别:他是 S3 主盘 + NVMe 缓存,本方案是 NVMe 主盘 + S3 兜底;精神一致。

2. **OpenMetal 案例 —— 裸机 + OpenStack + Ceph 的 ClickHouse 部署**
   https://openmetal.io/resources/case-studies/architecture-big-data-clickhouse-deployment
   命中 **1 + 3 + 4 + 5**。真实生产(网安公司):6 台裸机、每台 1 TB RAM、约 268 TiB 本地 Micron NVMe 当"热层",S3 兼容 Ceph 当"冷/历史"层。大专属节点 + 本地 NVMe + 对象存储兜底一次全占。**最接近主张 3–5 的真实命名生产案例。**

3. **ClickHouse LogHouse(原厂自己)**
   https://clickhouse.com/blog/building-a-logging-platform-with-clickhouse-and-saving-millions-over-datadog
   命中 **1 + 2 + 3 + 4**。K8s + 自研 operator + m5d.16xlarge(本地 NVMe)+ 200 GiB RAM/节点 + 单集群不分片。原厂自己就在跑大节点本地盘 K8s。

4. **Altinity "8 developer tricks" deck**(+ 配套 "Kubernetes Storage" deck)
   https://altinity.com/wp-content/uploads/2024/02/Eureka-8-developer-tricks-for-running-ClickHouse-on-Kubernetes-2024-02-27.pdf
   稳固命中 **2 + 3**,并预告 4/5("Where we are going next: Object storage for sure, using NVMe SSD for local cache")。本仓库调研引用的核心 Altinity K8s 运维指南。

---

## 结论

- **主张 1、2、5 基本是主流/原厂认可。**
- **主张 3 逐条有强支撑,但完整组合需自行组装**——本方案的系统化即增量价值。
- **主张 4(本地盘代替 EBS)是最有主见的选择**——成本导向实践者力挺 + 一个强裸机生产案例(OpenMetal),但明确不是 ClickHouse Inc 的默认推荐,且 OSS 靠副本兜 durability 意味着 N 份完整本地拷贝。

**一句话**:本方案不是标新立异,而是把"原厂认可(1/2/5)+ 社区力挺但非默认(3/4)"的实践系统化组装成一套可评审 IaC。而且没有任何公开实践把这五条全部打包成 turnkey 的 EKS IaC——mrkrbrts 是博客、OpenMetal 是裸机案例、LogHouse 是原厂内部。**本仓库填的正是这个空位。**
