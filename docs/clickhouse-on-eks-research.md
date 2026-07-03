# ClickHouse on Amazon EKS 生态与最佳实践调研报告

> 调研日期:2026-07-03
> 方法:深度研究工作流(5 个搜索角度 · 抓取 21 个来源 · 提取 103 条断言 · 对 top 25 条做 3 票对抗式验证,22 条确认 / 3 条推翻)
> 证据可信度说明:大量证据为厂商一手资料(Altinity / ClickHouse 官方),对"能力性事实"可靠;但"最成熟""测试最充分""最干净的方式"等措辞属自我宣传,缺乏独立量化。版本数字会随时间漂移。

---

## 一、核心结论:Operator 是整个生态的中心

**Altinity Kubernetes Operator for ClickHouse 是事实标准**,没有第二个成熟到能与之竞争的选择。

| 属性 | 事实(2026-07-03 核实) |
|---|---|
| 许可证 | Apache 2.0 |
| Stars / Releases | ~2,526 stars,88 个 release,最新 **0.27.1(2026-06-04)** |
| 平台覆盖 | **明确在 AWS EKS** 测试(以及 GKE / AKS / Minikube) |
| 背书 | 自 2019 年起是 **Altinity.Cloud 的底层**,用户含 eBay、Cisco、Twilio |
| 成熟度 | ★★★★★ 生产级,推荐默认选择 |

来源(primary):
- https://github.com/Altinity/clickhouse-operator
- https://altinity.com/kubernetes-operator
- https://docs.altinity.com/altinitykubernetesoperator

**权威模式验证**:ClickHouse 官方的 BYOC on AWS 本身就是这个模式——在客户 VPC 里的 EKS 上跑一个 ClickHouse operator + 配套服务(ingress、DNS、证书管理、state exporters、scrapers),日志/指标存 EBS,用 Prometheus/Thanos 栈。管理面在 ClickHouse 自有 VPC,通过私有端点访问、不直接接触客户数据。这等于官方用规模化生产验证了 "operator on EKS" 这条路。
- https://clickhouse.com/docs/cloud/reference/byoc/architecture
- https://clickhouse.com/blog/building-clickhouse-byoc-on-aws

> ⚠️ **重要 open question**:ClickHouse Inc. 于 **2026 年 1 月推出了官方的 ClickHouse Kubernetes Operator**(区别于 Altinity 的)。本次研究未独立核实其功能 / 成熟度 / EKS 支持。选型前需专门调研——若官方 operator 已成熟,长期可能改变默认推荐。

---

## 二、协调层:ClickHouse Keeper(而非 ZooKeeper)

新部署一律用 **ClickHouse Keeper**,ZooKeeper 只在存量迁移时保留。

- C++ 单二进制,**无 JVM / 无外部依赖**;客户端协议兼容 ZooKeeper;共识用 **NuRAFT(Raft)**,ZK 用 ZAB。
- 负责副本同步和分布式 DDL;**部分特性(如 S3Queue)强制要求 Keeper**(ClickHouse GitHub issue #70398)。
- **集群规模:奇数节点,推荐 3 个**。Altinity 明确**不建议超过 3 个投票节点**(observer 除外)——更大的集群会拖慢 leader 选举和 commit,进而拖慢 insert/DDL 延迟。
- **K8s 上部署方式**:用专门的 `ClickHouseKeeperInstallation`(CHK)CRD(`clickhouse-keeper.altinity.com/v1`),`tcp_port 2181`、raft server port `9444`、`storage_path /var/lib/clickhouse-keeper`、`four_letter_word_white_list`。CHK 自 operator **0.24.0 起生产可用**,0.27.x 支持 CHI 引用 CHK。

来源:
- https://kb.altinity.com/altinity-kb-setup-and-maintenance/altinity-kb-zookeeper/clickhouse-keeper
- https://clickhouse.com/docs/guides/sre/keeper/clickhouse-keeper

> ⚠️ **纠偏(被验证推翻的说法)**:"每个 ClickHouse 集群都必须引用 Keeper" 是**夸大**的。Keeper 是强烈推荐,但非普遍强制(单分片无副本、不用分布式 DDL 的场景可以没有)。

---

## 三、监控栈

**推荐:内置 / operator exporter + Prometheus + Grafana。**

- ClickHouse **自带 Prometheus endpoint**(端口 `9363`,`/metrics`),现代版本(~20.3+)已让老的外部 `clickhouse_exporter` 变得没必要(该项目已不维护)。
- 通过 operator 时用它的 **metrics-exporter**(端口 `8888`,`/metrics`)。
- 现成 Grafana 面板:官方 **Altinity operator dashboard #12163**。

来源:
- https://kb.altinity.com/altinity-kb-setup-and-maintenance/altinity-kb-monitoring
- https://github.com/ClickHouse/clickhouse_exporter
- https://grafana.com/grafana/dashboards/12163

---

## 四、生产级最佳实践:跨 AZ 与调度

**核心目标:副本跨 AZ + 跨主机分散,避免单点 / 单可用区故障。**

- **Operator 自动模式**:设 `topologyZoneKey=topology.kubernetes.io/zone` + `nodeHostnameKey=kubernetes.io/hostname`。
- **手动模式**:`podTemplate.affinity` + `topologySpreadConstraints` + zone / instance-type 节点选择器。
- **每主机一 Pod**:`podAntiAffinity`(`requiredDuringSchedulingIgnoredDuringExecution`,topologyKey=`kubernetes.io/hostname`)+ `nodeAffinity`(`topology.kubernetes.io/zone`)。官方示例:`10-zones-02-advanced-02-aws-pod-per-host.yaml`。

来源:
- https://clickhouse.com/docs/clickhouse-operator/guides/configuration
- https://github.com/Altinity/clickhouse-operator
- https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints
- Altinity "8 developer tricks for running ClickHouse on Kubernetes" (2024-02-27 PDF)

> ⚠️ 小坑:主机标签是 `kubernetes.io/hostname`,不是 `topology.kubernetes.io/hostname`(某来源写错了)。

---

## 五、快速起步:官方 Terraform Blueprint

**绿地首选:Altinity 开源的 Terraform AWS EKS Blueprint(与 AWS EKS 团队合作开发)。**

- 一把梭:**EKS + EBS + autoscaling + operator + ClickHouse + Keeper**。
- 简化到"改几行控制文件 + 两条 terraform 命令"。
- 默认用 **ClickHouse Keeper(不是 ZooKeeper)**。

来源:
- https://altinity.com/blog/introducing-the-terraform-aws-eks-blueprint-for-clickhouse
- https://github.com/Altinity/terraform-aws-eks-clickhouse

> ⚠️ 注意:README 警告底层 AWS EKS Blueprints 模块的 provider 版本可能滞后;且 "blueprint 负责 backup/recovery" 的说法未被证实(它确认部署 operator,但备份 / 恢复范围没依据)。

---

## 六、诚实的空白(本次未充分覆盖 —— 建议下一步深挖)

以下为问题中点名、但**没有被确认性证据支撑**的点,不要当成已解决:

1. **官方 ClickHouse Operator(2026-01 发布)** 的能力 / 成熟度 / 与 Altinity 的对比 —— 选型关键,需专门查。
2. **存储选型细节**:EBS CSI vs local NVMe、gp3 IOPS/吞吐调优、卷扩展、`WaitForFirstConsumer` 绑定、**EBS 的可用区绑定性 vs 副本跨 AZ 放置的冲突** —— 有状态负载在 EKS 上最容易踩的坑,本次未拿到确证。
3. **clickhouse-backup 与 operator 集成**:S3 目标、调度、恢复流程、增量备份 —— 问题里点名了,但没有一条断言活下来。
4. **有状态负载的 K8s 陷阱**:EBS 跨 AZ detach/reattach 延迟、PVC/StatefulSet 重调度、滚动升级顺序与副本 quorum 安全、磁盘写满恢复 —— 未证实,值得专门研究。

---

## 附录 A:被对抗式验证推翻的说法(反面清单)

| 被推翻的说法 | 投票 | 说明 |
|---|---|---|
| "Altinity operator 是 GitHub 上最流行的数据库 operator 之一,>1600 stars" | 1-2 | 陈旧;准确数字为 ~2.5k stars,措辞属营销 |
| "每个 ClickHouse 集群都必须引用一个 Keeper 集群" | 1-2 | 夸大;Keeper 是推荐而非普遍强制 |
| "blueprint 部署 operator 以管理扩缩容、备份和恢复" | 1-2 | operator 部署确认,但备份/恢复范围无依据 |

## 附录 B:来源清单(按角度)

**broad/primary — operators 概览与对比**
- https://github.com/Altinity/clickhouse-operator (primary)
- https://altinity.com/kubernetes-operator (primary)
- https://pulse.support/kb/clickhouse-kubernetes-operator (blog)
- https://www.tinybird.co/blog/altinity-cloud-managed-clickhouse (blog)

**authoritative refs — 厂商与官方文档**
- https://clickhouse.com/docs/cloud/reference/byoc/architecture (primary)
- https://docs.altinity.com/altinitykubernetesoperator (primary)
- https://kb.altinity.com/altinity-kb-setup-and-maintenance/altinity-kb-zookeeper/clickhouse-keeper (primary)
- https://clickhouse.com/blog/building-clickhouse-byoc-on-aws (primary)
- https://altinity.com/blog/whats-new-in-the-altinity-kubernetes-operator-for-clickhouse (blog)

**practitioner/implementation — EKS 配套组件**
- https://clickhouse.com/docs/clickhouse-operator/guides/configuration (primary)
- https://altinity.com/webinarspage/all-about-zookeeper-and-clickhouse-keeper-too (secondary)
- https://clickhouse.com/docs/guides/sre/keeper/clickhouse-keeper (primary)
- https://kb.altinity.com/altinity-kb-setup-and-maintenance/altinity-kb-monitoring (primary)

**production best practices — 拓扑、调度、HA**
- https://altinity.com/wp-content/uploads/2024/02/Eureka-8-developer-tricks-for-running-ClickHouse-on-Kubernetes-2024-02-27.pdf (primary)
- https://altinity.com/blog/introducing-the-terraform-aws-eks-blueprint-for-clickhouse (primary)
- https://clickhouse.com/docs/architecture/cluster-deployment (primary)
- https://clickhouse.com/blog/clickhouse-kubernetes-operator (primary)
- https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints (primary)
- https://altinity.com/blog/keeping-clickhouse-open-and-portable-in-altinity-cloud (blog)

**contrarian/skeptical — 有状态负载陷阱**
- https://clickhouse.com/blog/make-before-break-faster-scaling-mechanics-for-clickhouse-cloud (primary)
- https://www.tinybird.co/blog/what-i-learned-operating-clickhouse (blog)
