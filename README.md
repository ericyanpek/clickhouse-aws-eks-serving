# ClickHouse on Amazon EKS —— 生产级部署方案

**中文** · [English](./README.en.md)

> 一套将 ClickHouse 以 **1 分片 × 3 副本** 拓扑部署到 Amazon EKS 的可评审、可执行 IaC。
> 复用 Altinity 官方 Terraform 蓝图的基础设施层,替换其封闭的集群层,换取对分片/副本拓扑、本地 NVMe、调度亲和性与备份的完全控制。
>
> 操作手册见 [`README.en.md`](./README.en.md)(英文,含前置条件、部署步骤、验证、成本、销毁)。本文只讲**方案的意义、取舍与相对上游蓝图的差异**。

---

## 1. 这套方案解决什么问题

在 AWS 上运行生产级 ClickHouse 有多条成熟路径,各自面向不同需求,并无绝对优劣:

- **ClickHouse Cloud on AWS**(AWS Marketplace 可采购):原厂托管 SaaS。存算分离架构(SharedMergeTree + S3 对象存储),计算按需自动伸缩、可 idle,工程与管理优化成熟,轻运维。**面向希望把运维完全交给原厂、按用量付费、快速上线的团队**——这是多数场景下省心且稳妥的首选。详见 [§3.6 与 ClickHouse Cloud on AWS 的对比](#36-与-clickhouse-cloud-on-aws-的对比)。
- **Altinity Terraform EKS Blueprint**(官方、与 AWS EKS 团队合作):自管路线的成熟起点。基础设施层(VPC / EKS / 节点组 / IAM / autoscaler)久经考验;但其内置的 ClickHouse 集群层把拓扑封装在上游 Helm chart 内,仅暴露 zones / instance_type / name / user / password 五个参数,难以表达自定义分片副本、本地 NVMe、反亲和调度、备份等生产诉求。
- **本方案**:同属自管路线,在蓝图基础上做**针对性取舍**——复用其成熟的基础设施层,把封装的集群层替换为**自管的 CHI/CHK 声明式清单**。在"不重造 VPC/EKS 轮子"的同时,拿回对 ClickHouse 拓扑、存储、调度与运维的完全控制权。

**本方案的定位不是取代托管服务,而是覆盖"需要完全运行在自己 AWS 账号内、深度定制、本地 NVMe IO 特性、并纳入自有 IaC/GitOps/合规体系"的场景。** 若这些不是硬需求,ClickHouse Cloud on AWS 往往是更省心的选择。

---

## 2. 出处与依据(Provenance)

本方案不是凭空设计,而是在权威来源上做减法与定制。所有引用均可追溯:

| 来源 | 用途 | 链接 |
|---|---|---|
| **Altinity Terraform AWS EKS Blueprint** `v0.5.7` | 复用其 `//eks`(VPC/EKS/节点组/IAM/autoscaler)与 `//clickhouse-operator` 子模块 | https://github.com/Altinity/terraform-aws-eks-clickhouse |
| **Altinity Kubernetes Operator for ClickHouse** `0.27.1` | 通过 CHI / CHK CRD 声明式管理 ClickHouse 集群与 Keeper | https://github.com/Altinity/clickhouse-operator |
| **ClickHouse 官方 BYOC on AWS** | 验证了 "operator-on-EKS" 模式在规模化生产中的可行性 | https://clickhouse.com/blog/building-clickhouse-byoc-on-aws |
| **ClickHouse Keeper 官方文档 / Altinity KB** | 协调层选型(NuRAFT,替代 ZooKeeper)与 3 节点奇数 quorum | https://clickhouse.com/docs/guides/sre/keeper/clickhouse-keeper |
| **sig-storage local-static-provisioner** `2.8.0` | 将 i8g 本地 NVMe 发布为 `local` PV | https://github.com/kubernetes-sigs/sig-storage-local-static-provisioner |
| **kube-prometheus-stack** + Altinity Grafana dashboard `#12163` | 监控栈 | https://grafana.com/grafana/dashboards/12163 |

调研与设计依据(仓库内):
- [`docs/clickhouse-on-eks-research.md`](./docs/clickhouse-on-eks-research.md) —— 生态组件与最佳实践调研(多源交叉验证,带引用)
- [`docs/notes-ck-on-eks-best-practices-2026.md`](./docs/notes-ck-on-eks-best-practices-2026.md) —— 拓扑/机型/资源模型/存储/恢复的推演笔记(本方案拓扑对齐的依据)
- [`docs/superpowers/specs/2026-07-03-clickhouse-on-eks-design.md`](./docs/superpowers/specs/2026-07-03-clickhouse-on-eks-design.md) —— 设计规格
- [`docs/perf-testing-plan.md`](./docs/perf-testing-plan.md) —— 性能与压力测试计划(数据集与流程,带核实的出处)
- [`docs/community-corroboration.md`](./docs/community-corroboration.md) —— **社区/官方对本方案五条设计主张的印证**(附最接近的真实实践与诚实 caveat)

---

## 3. 与上游蓝图的关键差异

这是本方案的核心价值所在。**复用 = 蓝图已验证的部分;替换/新增 = 蓝图表达不了、但生产必需的部分。**

| 维度 | Altinity Blueprint(默认) | 本方案 | 为什么这么改 |
|---|---|---|---|
| **基础设施层** | `//eks` 子模块 | ✅ **原样复用**(钉 `v0.5.7`) | 成熟、AWS 官方合作,不重造轮子 |
| **Operator 安装** | `//clickhouse-operator` | ✅ **复用**,版本钉到 `0.27.1`(覆盖默认 0.24.4) | 用近期稳定版,可复现 |
| **集群拓扑层** | `//clickhouse-cluster`(封闭 Helm chart) | ❌ **弃用**,改为自管 CHI/CHK 清单 | 蓝图只暴露 5 个参数,无法表达下列所有定制 |
| **分片 / 副本** | 写死在 chart | **1 分片 × 3 副本**,可任意调整 | "先垂直扩容,分片最后"——分片无自动 rebalance,3 副本兼顾 HA 与读扩展 |
| **存储** | 写死 `gp3-encrypted`(EBS) | **本地 NVMe**(i8g,~3.75TB)+ local-static-provisioner | merge/扫描是重 IO,本地盘直连 PCIe 显著更快;durability 交给 3 副本 + S3 |
| **机型** | 通用 x86 | **i8g.4xlarge(ARM/Graviton)** | ClickHouse 在 Graviton 上性价比领先;官方一等公民 |
| **资源模型** | chart 默认 | 专属节点:**CPU request 高 / 不设 limit**,内存 **request==limit**,`max_server_memory_usage_to_ram_ratio: 0.9` | 独占节点上 CPU limit 会触发 CFS throttle 伤查询延迟;为 page cache 留余量 |
| **调度** | 有限 | **一 Pod 一节点** + hostname 反亲和 + 跨 3 AZ zone spread + PDB | 副本不同机不同 AZ,单点/单可用区故障不致命 |
| **Keeper** | 随 chart | **独立 CHK**(3 节点跨 AZ,gp3,PDB minAvailable=2) | 协调层与数据层隔离,是硬性最佳实践 |
| **备份** | ❌ 无 | **clickhouse-backup → S3**,经 IRSA 授权,每日 CronJob | 本地盘无快照,S3 备份是唯一灾难兜底 |
| **NVMe 挂载** | ❌ 不处理 | **bootstrap DaemonSet** 格式化并挂载 i8g 本地盘至 `/mnt/disks` | AL2023 不自动挂 instance store,不处理则 PVC 永久 Pending |
| **apply 流程** | 单次 | **两阶段 apply**(先 AWS 基础设施,再 in-cluster helm/k8s 资源) | 避免 helm/kubernetes provider 连接尚未就绪的集群导致中途卡死 |
| **销毁流程** | 单次 destroy | **两阶段 teardown**(先删 in-cluster 资源,再删集群) | 避免 destroy 时 provider 竞争导致状态损坏、资源残留计费 |

被验证推翻的上游宣传(见调研报告):蓝图"负责 backup/recovery"未被证实——它只部署 operator,备份能力需自建(即本方案第 4/6/11 项)。

**相较蓝图的进阶价值,提炼为四点:**
1. **拓扑与存储自主**:蓝图把集群层锁死在 5 个参数;本方案用声明式 CHI/CHK 拿回分片副本、本地 NVMe、存储类的完全控制——这是从"能跑"到"按需生产化"的关键差别。
2. **性能选型到位**:Graviton(i8g)+ 本地 NVMe 直连 + 专属节点资源模型(CPU 不设 limit 避免 CFS throttle、内存 request==limit、page cache ratio),把单节点性能压到该机型的上限——蓝图默认的通用 x86 + gp3 达不到。
3. **生产必备的补齐**:独立 Keeper + PDB、跨 AZ 反亲和、clickhouse-backup→S3(蓝图完全没有)、i8g NVMe 自动挂载(蓝图不处理,否则 PVC 永久 Pending)。
4. **流程健壮性**:两阶段 apply(避开 helm provider 连接未就绪集群)、两阶段 teardown(避免 provider 竞争导致状态损坏/资源残留计费)——这些是蓝图单次 apply/destroy 不具备的工程加固,来自真实部署中踩过的坑。

---

## 3.5 与 AWS `data-on-eks` 参考栈的对比

AWS 官方的 [data-on-eks](https://awslabs.github.io/data-on-eks/docs/datastacks/databases/clickhouse-on-eks/infra) 提供了另一个 ClickHouse-on-EKS 参考实现。两者**同源(都基于 Altinity operator)、异路**:它是"功能全开的数据平台样板",本方案是"为特定定位做减法的精简生产方案"。

| 维度 | AWS data-on-eks(参考栈) | 本方案 | 实质 |
|---|---|---|---|
| 节点伸缩 | **Karpenter**(按需/Spot,pod 驱动) | cluster-autoscaler(蓝图自带,固定节点组) | 平台弹性 vs 依赖少、可评审 |
| 应用交付 | **ArgoCD(GitOps)** 全家桶 | 裸 Terraform + kubectl | 平台工程 vs 心智负担低 |
| 拓扑 | **3 分片 × 3 副本(9 Pod)** | **1 分片 × 3 副本(3 Pod)** | 展示分布式全貌 vs "先扩容、后分片" |
| 机型 | Graviton m6g.8xlarge | Graviton i8g.4xlarge | 都 ARM,存储家族不同 |
| 存储 | **EBS gp3 500Gi/副本** | **本地 NVMe ~3.75TB** | 稳妥恢复快 vs IO 上限高(靠副本+S3 兜底) |
| Operator / Keeper | Altinity / 3 节点 | Altinity 0.27.1 / 3 节点 + PDB | 同源 |
| 反亲和 / 备份 | 文档未体现 | 显式反亲和+zone spread+PDB / clickhouse-backup→S3 | 本方案更严格、补齐备份 |

**三个关键分歧不是对错,是定位不同:**
- **Karpenter/ArgoCD vs 固定节点组/Terraform**:前者面向"已有平台团队的数据平台",后者面向"要一套可控的 ClickHouse,而非一套平台"。
- **3×3 vs 1×3**:前者演示分布式,后者遵循"scale-up first, shard last"(分片无自动 rebalance,先垂直做大 + `parallel_replicas`)。
- **EBS vs 本地 NVMe**:前者稳妥,后者为压测/serving 加速追求 IO 上限,并配齐其前提(跨 AZ 反亲和 + S3 备份 + NVMe 挂载)。

> 一句话:**data-on-eks 教你"分布式怎么搭";本方案主张"先别急着分布式",并把依赖收敛到最小。** 两者可互为参照——见下节"演进方向"。

## 3.6 与 ClickHouse Cloud on AWS 的对比

[ClickHouse Cloud on AWS](https://clickhouse.com/cloud)(AWS Marketplace 可采购)是原厂托管 SaaS,也是多数团队的稳妥首选。它与本方案是**两种架构范式**,不是"托管版 vs 弱化版"——真正的区别在架构哲学与运维模型,各有最佳场景。

| 维度 | ClickHouse Cloud on AWS(原厂 SaaS) | 本方案(自管 EKS) | 实质 |
|---|---|---|---|
| 运维模型 | **全托管、轻运维**,原厂负责升级/伸缩/故障 | 自运维(operator 辅助),责任在自己 | ⭐ Cloud 的核心优势 |
| 存储架构 | **存算分离**,数据在 S3,`SharedMergeTree` | 存算一体,本地 NVMe,`ReplicatedMergeTree` | 范式不同(见下) |
| 弹性 | **计算独立伸缩、可 idle 近零、按用量计费** | 固定节点组(可演进到弹性) | ⭐ Cloud 优势 |
| 副本协调 | 经 S3 + Keeper,**副本间不互传数据** | 副本间 fetch part(interserver) | 各有取舍 |
| IO 路径 | 以 S3 为主(计算侧缓存机制官方未详述) | **本地 NVMe 直连**,低延迟高 IOPS | IO 敏感场景本方案理论占优 |
| 定制深度 | 平台化,定制在托管边界内 | **内核参数/调度/存储类/拓扑完全可改** | ⭐ 本方案优势 |
| 数据主权 | 标准版数据面在 CH 账号;另有 **BYOC**(数据面在你 VPC) | **完全在自己 AWS 账号内** | 各有选项 |
| 成本结构 | 按用量 + 托管价值(省人力) | 基础设施成本 + 自运维人力 | 结构不同,不宜简单比高低 |
| 采购/合规 | Marketplace 一键采购,原厂 SLA | 纳入自有 IaC/GitOps/合规审计流程 | 取决于组织要求 |

**先明确肯定 ClickHouse Cloud 的优势(都是真实的):** 原厂托管的轻运维体验、`SharedMergeTree` 面向对象存储的工程优化(更高插入吞吐、更好的后台 merge、副本扩展无需互传数据)、计算的弹性伸缩与 idle、以及 AWS Marketplace 的采购便利与原厂 SLA。**对绝大多数希望"专注业务、少碰基础设施"的团队,它是更优解。**

**本方案的差异化价值,在于覆盖托管边界之外的场景:**
- **完全自持**:全部资源运行在自己的 AWS 账号内,满足强数据主权/合规审计诉求(BYOC 也能自持,但本方案的定制自由度更高)。
- **深度定制**:内核参数、调度亲和、存储类、拓扑均可改到位——托管服务出于稳定性会限制这类底层旋钮。
- **本地 NVMe 的 IO 特性**:存算一体 + 本地盘直连,在对**热数据低延迟扫描/点查**敏感的场景有架构层面的 IO 优势。
- **纳入自有 IaC 体系**:整套是可评审的 Terraform + 声明式清单,天然融入既有 GitOps/CI/合规流程。

> **严谨说明**:两者的 IO 路径不同(本地 NVMe 直连 vs S3+缓存),本方案在 IO 敏感负载上**理论**有延迟优势,但官方未提供与自管本地盘的量化对比,故本仓库**不声称"更快"**——请以自身负载在 [`docs/perf-testing-plan.md`](./docs/perf-testing-plan.md) 下实测为准。选型应回到需求:**要省心与弹性 → ClickHouse Cloud;要自持、定制与本地盘 IO → 本方案。**

## 4. 架构一览

```
┌───────────────────────────── 新建 VPC (3 AZ) ─────────────────────────────┐
│  EKS 集群                                                                  │
│   ├─ system 节点组 (t3, gp3)     : operator / kube-prometheus-stack        │
│   ├─ clickhouse 节点组 (i8g.4xlarge, 本地 NVMe, 3× 跨 AZ)                   │
│   │     shard0-replica0 (a)   shard0-replica1 (b)   shard0-replica2 (c)    │
│   │     —— 一 Pod 一节点,反亲和 + zone spread,CHI CRD 声明               │
│   └─ system-keeper 节点组 (t3, gp3, 3× 跨 AZ)  : ClickHouse Keeper (CHK)   │
└────────────────┬───────────────────────────────────┬──────────────────────┘
                 │ IRSA                               │ 每日备份
                 ▼                                    ▼
        ClickHouse Service (ClusterIP)         S3 Bucket (加密/版本化/阻断公有)
```

- **分层解耦**:Terraform 管 AWS 基础设施 + Helm addons;Kubernetes 清单管 ClickHouse 业务拓扑(CHI/CHK)。改拓扑不动 Terraform。
- **协调层**:ClickHouse Keeper(C++/NuRAFT,ZooKeeper 协议兼容),3 节点奇数 quorum,独立于数据节点。

---

## 5. 适用边界(严谨说明)

本方案针对一个**明确定位**做了自洽取舍,范围内接近最优;超出范围时取舍会变,不应硬套:

- **✅ 适用**:ClickHouse 作为湖仓/数仓下游的轻量 OLAP / BI serving 加速层;读多写少;有上游可重灌数据兜底 durability。
- **⚠️ 需重估**:
  - 若 ClickHouse 是**唯一数据源(SoT)**、无上游兜底 → 本地 NVMe 的"会丢"不再可接受,应回到 EBS + 备份为主。
  - 若**极高吞吐实时摄入**(写重于读)→ 写放大成为主约束,副本/分片策略需重估。
  - 若**超大规模、单查询需跨大量机器扇出** → 必须真正分片,1 分片 scale-up 顶不住;届时先用 `parallel_replicas` 推迟撞墙,再引入分片。

同时,本方案**只产出 IaC,不代为执行 `terraform apply`**——真实资源创建、配额、凭证与费用(约 $120–160/天)由使用者掌控。

---

## 6. 一句话总结

> **站在 Altinity 官方蓝图成熟的基础设施地基上,把它封闭、表达力不足的集群层,换成一套自管的、声明式的、面向生产的 ClickHouse 拓扑——用最小的重复劳动,换回对分片副本、本地 NVMe、调度亲和、备份与升级流程的完全控制。**
