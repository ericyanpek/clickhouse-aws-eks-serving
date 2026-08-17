# ClickHouse on Amazon EKS OLAP 加速层

**中文** · [English](./README.en.md)

> **架构前提:** 数据湖仓是唯一权威数据事实来源（Source of Truth, SoT），保存完整历史并支持重放。ClickHouse 只保存从湖仓派生、可重建的 MergeTree 数据，用作低延迟 OLAP / BI 查询加速层；它不是主数据存储，也不是唯一事实来源。
>
> 本仓库只部署 ClickHouse on EKS，不创建上游湖仓，也不实现 Kafka/Flink 摄入作业。采用本方案前，必须已经有可重放的数据湖仓和对应的批量或流式同步链路。仓库创建的 S3 bucket 仅用于 ClickHouse 备份/灾备，**不是湖仓 SoT**。

## 1. 项目定位与价值

本项目提供一套可评审、可执行的 Terraform + Kubernetes IaC，在自有 AWS 账号中部署：

- ClickHouse：**按需一个或多个独立集群**，默认单个 1 分片 × 3 副本集群，每副本独占一个跨 AZ 的 `r8g.4xlarge` 节点和独立 gp3 数据卷。
- ClickHouse Keeper：**每集群独立**一套 3 节点跨 AZ quorum，数据存放在持久化 EBS。
- Altinity ClickHouse Operator `0.27.1`。
- Prometheus、Grafana、每日 S3 备份和 IRSA 权限。
- NVMe 初始化、部署、验证、节点丢失恢复和有序销毁脚本。
- 单集群粒度的销毁（`teardown.sh --cluster <key>`），增删任一集群不影响其他集群。

集群集合由 Terraform 的 `clickhouse_clusters` map 定义，map 的 key 就是集群标识符。追加一个集群只需增加一个 key——因为节点组按字符串 key 而非列表序号编址，增删任一集群都不会改动其他集群的资源。每个集群可独立指定拓扑、存储介质、实例规格和 ClickHouse 版本。

数据卷介质是最主要的取舍点。实测后的**默认是 EBS gp3**（运维恢复优势明显、性能代价在主流场景内可忽略），本地 NVMe 作为存储密集场景的性能 profile 同等可用。依据与代价见 [4.3](#43-数据卷选型ebs-gp3-与本地-nvme)。

它的核心价值不是替代 ClickHouse Cloud，而是为以下场景提供自管参考实现：

- 数据必须完全运行在自己的 AWS 账号和 VPC 内。
- 需要控制 ClickHouse 拓扑、调度、内核参数、存储和升级节奏。
- 数据湖仓已经承接唯一数据事实，需要一个可重建的热查询加速层。
- 需要用同一套 IaC 做 POC、成本评估、性能验证和合规评审。

对于从 ClickHouse Cloud 迁移到 OSS 的 POC，本仓库可回答 EKS 部署、存储、HA、备份和运维问题；它**不包含** Kafka/Flink 双写、历史数据回填、结果比对或切流逻辑，这些属于上游数据管道。

## 2. 当前架构

```text
Kafka / Flink / Batch
         |
         | authoritative write
         v
Data Lakehouse on S3 (Iceberg / Delta / Hudi / Parquet)
唯一 SoT、完整历史、可重放
         |
         | incremental load / replay
         v
+------------------------- Amazon EKS, 3 AZ -------------------------+
| ClickHouse 1 shard x 3 replicas                                   |
|   i8g.4xlarge + local NVMe, one Pod per node                      |
|                                                                    |
| ClickHouse Keeper 3 nodes + EBS                                   |
| Altinity Operator + local-static-provisioner                      |
| Prometheus + Grafana                                               |
+------------------------------+-------------------------------------+
                               |
                               | daily backup via IRSA
                               v
                    S3 backup bucket (not the SoT)
```

关键属性：

| 维度 | 当前实现 |
|---|---|
| 数据角色 | 湖仓是唯一 SoT；ClickHouse 是最终一致、可重建的派生 OLAP 加速层 |
| ClickHouse 拓扑 | 1 shard × 3 replicas，固定 3 个数据节点 |
| 数据存储 | 默认每副本约 3.4 TiB 本地 NVMe，`ReplicatedMergeTree`；实测后推荐改用 gp3，见 [4.3](#43-数据卷选型ebs-gp3-与本地-nvme) |
| 协调层 | 3 节点 Keeper，EBS `gp3-encrypted` |
| 服务暴露 | `ClusterIP`，默认不公网暴露 |
| 灾备 | ClickHouse 副本 + 每日 S3 备份；全量权威恢复源仍是上游湖仓 |
| 镜像 | ClickHouse / Keeper `25.3` LTS |

## 3. 数据流与 Kafka/Flink 边界

推荐的数据责任划分：

1. Kafka/Flink 或批处理首先保证事件进入湖仓，湖仓保存完整、权威、可重放的数据。
2. 同一作业或独立派生作业把数据写入 ClickHouse，维护 watermark、幂等键、schema 映射和失败重放。
3. POC 期间可从同一标准化数据流双写 ClickHouse Cloud 与本项目部署的 OSS 集群。
4. 使用固定时间窗口、行数/聚合校验、查询结果 diff 和延迟指标验证两端一致性。
5. 切流后仍保留湖仓作为唯一 SoT；ClickHouse 集群可以从湖仓重新物化。

可选摄入方式包括 Flink ClickHouse connector、Kafka engine + Materialized View、从 Iceberg/Parquet 批量 `INSERT SELECT`，或外部编排的增量回填。具体选择取决于交付语义和吞吐量，本仓库不替用户实现或承诺 exactly-once。

## 4. 关键设计取舍

### 4.1 EKS 与 EC2

- 已有 Kubernetes 平台团队、需要 GitOps/统一可观测性和调度策略时，EKS 更适合。
- 只运行单个 ClickHouse 集群且希望减少控制面复杂度时，EC2 通常更直接。
- 本仓库选择 EKS，是为了复用 Altinity Operator 和现有平台能力，不代表 EKS 对所有场景都优于 EC2。

### 4.2 一分片三副本

默认先垂直扩容，再考虑分片。增加 shard 不会自动搬迁历史数据；只有当单节点容量或单查询算力成为瓶颈时，才应设计真正的重分片流程。3 个副本用于跨 AZ 可用性和读扩展，不改变湖仓的 SoT 地位。

### 4.3 数据卷选型：EBS gp3 与本地 NVMe

> **仓库默认已是 EBS gp3。** `clickhouse_clusters` 的默认值是一个 `storage_profile = "ebs"` 的集群，`./scripts/deploy.sh` 据此渲染 CHI 并挂载每集群独立的 gp3 卷。本地 NVMe 仍是一等选项，只需把该集群的 `storage_profile` 改为 `"local-nvme"`；依据与代价见下。

#### 4.3.1 实测结论

2026-08-12 的 [同轮存储选型实验](./docs/storage-selection-report.md) 在同一 EKS 集群内并行部署两种介质，同版本、同拓扑、同资源配额、同一压测客户端：

| 场景 | 结果 | 谁更好 |
|---|---|---|
| warm ClickBench（工作集入内存） | 差异 +2.8%–3.9% | 同档 |
| direct I/O（强制绕过 page cache） | EBS 慢 66%–78%，个别查询 3 倍 | **本地盘** |
| `OPTIMIZE FINAL` merge 收敛 | EBS 慢 48%（4,916s vs 3,321s） | **本地盘** |
| 节点永久丢失恢复 | EBS 111 秒重挂原卷、零重建；本地盘需重灌约 130 GiB | **EBS** |
| 月成本（1×2，不含共享成本） | 本地盘 $2,004.29；EBS $2,180.14 | 本地盘便宜 8.77% |

merge 那一行的机制值得单独说明：两种介质**累计搬运的字节数几乎相同**（每节点约 1.0 TiB），差异完全来自持续吞吐（217 vs 328 MiB/s）。EBS 在 merge 期间设备利用率已达 102%、p95 顶到 1,130–1,193 MiB/s（预置上限 1,250）；本地 NVMe 峰值可达 2,630–2,815 MiB/s 而利用率仍不足 89%。**这是能力余量的差距——EBS 的上界是买来的，实例存储的上界是硬件给的。**

#### 4.3.2 为什么默认推荐 EBS

在本项目的架构前提下（湖仓是 SoT，ClickHouse 是可重建加速层），EBS 的优势集中在运维而非性能：

- **节点替换不需要重灌数据。** [2026-08-13 HA 演练](./docs/ha-drill-report.md) 实测：停掉一个数据节点，原卷 111 秒内重新挂载到同 AZ 替换节点，**数据零重建**，服务中断仅 3 秒。本地盘同场景必须触发 [`recover-local-replica.sh`](./scripts/recover-local-replica.sh) 从健康副本或湖仓重灌约 130 GiB，RTO 由数据量决定。
- **常规运维动作零中断。** Pod 删除、`kubectl drain` 优雅驱逐在演练中均为零失败查询。节点滚动升级、AMI 轮换、autoscaler 缩容因此都是低风险操作。
- **容量与实例解耦。** 存储大小不再受实例规格的 instance-store 容量约束，可独立扩容，也可在线调整 IOPS/吞吐而不重建节点。
- **性能代价在主流场景内可忽略。** warm 查询同档；只有在存储密集场景才显著落后。

代价是**每月贵 8.77%**，以及**维护窗口需按 1.5 倍规划**（merge 慢 48%）。对于一个可重建的加速层，用 8.77% 换掉"节点挂了要重灌 130 GiB"这个运维负担，通常是划算的。

#### 4.3.3 什么时候仍应选本地 NVMe

以下任一条成立时，本地盘的性能优势具备决策意义：

- 查询工作集**显著超出内存**，存在频繁绕过 page cache 的大扫描（direct I/O 场景 EBS 慢 66%–78%）。
- 有**严格的 direct-I/O 尾延迟** SLA。
- 后台 merge 必须在**固定夜间窗口**内完成，48% 的差距会导致窗口溢出。
- 需要**持续超过实例 EBS 通道**的吞吐。注意 `r8g.4xlarge` 是突发型规格：1,250 MB/s 每 24 小时只能维持 30 分钟，之后回落到 625 MB/s 基线。若持续负载确实需要高吞吐，正确做法是升到基线等于最大值的 `r8g.8xlarge`，而不是给卷加预置。

选择本地盘就必须接受：节点终止即数据永久丢失、local PV 不会自动漂移、恢复需人工触发。**该取舍只在 ClickHouse 数据可从湖仓重建时成立**；若 ClickHouse 是唯一数据源，本仓库的恢复模型不适用。

#### 4.3.4 如何切换

要在自己的数据和查询上复现上述对比，在 `clickhouse_clusters` 中同时声明两个集群（一个 `storage_profile = "ebs"`、一个 `"local-nvme"`），两者共用同一 EKS、监控和压测节点。历史材料另有 2026-08-11 的 [EBS-only 实测](./docs/storage-comparison-results.md)。

切换到 EBS 需要同时调整：CHI 的 `storageClassName`（`local-storage` → gp3 类）、实例类型（`i8g` → `r8g`）、以及节点组的子网绑定——**gp3 卷是 AZ 绑定资源，节点组必须绑定单一子网**，否则替换节点可能落到其他 AZ 而无法挂载原卷，4.3.2 的恢复优势将不成立。

### 4.4 S3 备份

`clickhouse-backup` 保存的是 ClickHouse 恢复点，用于缩短灾难恢复时间。备份桶不替代湖仓，默认 teardown 后继续保留，并从 Terraform state 移除。

## 5. 与其他方案的关系

- **ClickHouse Cloud on AWS**：原厂托管、轻运维、弹性更强，通常是没有自管硬需求时的优先选择。
- **Altinity Terraform EKS Blueprint**：本项目复用其 VPC/EKS/节点组和 operator 基础设施层，但用自有 CHI/CHK 清单替换其封装的集群层。
- **AWS data-on-eks**：更偏完整数据平台样板；本项目聚焦固定 1×3、专属节点、可选存储介质和较少依赖。

本项目相对上述方案的差异化价值之一，是把存储介质选型做成了**可复现的实测**而不是经验判断：同一集群内并行部署两种介质，产出查询、merge、设备级 I/O、恢复 RTO 和成本五类证据，并明确标注哪些结论不成立。设计依据、实测报告和历史材料的状态见 [文档索引](./docs/README.md)。

## 6. 前置条件与成本

需要：

- Terraform `>= 1.5`
- AWS CLI 和可用凭证
- `kubectl`、Helm 3
- EKS、VPC/EC2、IAM、S3 权限
- 目标区域内至少 3 台 `i8g.4xlarge` 的配额和容量；若按 [4.3](#43-数据卷选型ebs-gp3-与本地-nvme) 改用 gp3，则改为 3 台 `r8g.4xlarge` 加对应的 gp3 容量与 IOPS 配额
- 已存在的数据湖仓、schema 管理和可重放摄入链路

> **容量风险（实测遇到过）：** 2026-08-12 的实验中 `us-east-1b` 和 `us-east-1c` 都无法提供所需的 `i8g.4xlarge`，被迫把两个副本放进同一个 AZ，导致该轮的跨 AZ 与 HA 结论失效。`i8g` 这类较新的存储优化机型在部分 AZ 供给紧张，规划跨 AZ 拓扑前应先用 Service Quotas 和实际 `run-instances` 试探确认容量，而不是假设配额等于可得。

该部署持续运行时成本显著，包括 3 台数据节点、3 台 Keeper 节点、3 台 system 节点、1 台 benchmark 节点、NAT Gateway 和 EKS 控制面。选用 gp3 时还需计入每副本的卷容量、超出免费额度的 IOPS 与吞吐费用。价格随区域和时间变化，apply 前必须使用 AWS Pricing Calculator 和 Service Quotas 核实，不应把仓库中的历史估算当报价。

## 7. 配置

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

至少检查：

```hcl
region              = "us-east-1"
availability_zones  = ["us-east-1a", "us-east-1b", "us-east-1c"]

backup_bucket_name  = ""
public_access_cidrs = ["203.0.113.0/24"]

# The set of clusters. Defaults to a single ebs cluster; add a key to add a cluster.
clickhouse_clusters = {
  ebs = {
    storage_profile = "ebs"
    shards          = 1
    replicas        = 3
  }
  # nvme = {
  #   storage_profile = "local-nvme"
  #   shards          = 1
  #   replicas        = 3
  # }
}
```

`availability_zones` 必须是同一区域内三个真实、不同的 AZ，且每个集群的 `zones` 必须是它的子集。`public_access_cidrs` 默认值会开放 EKS 公网 API，生产环境必须收紧。

每集群的 `cpu_request`、`memory_request` 和 `data_volume_size_gib` 默认按 16 vCPU / 128 GiB 的 Graviton 规格定尺。改 `instance_type` 时必须同步调整这三项，否则 Pod 会因资源超过节点可分配量而无法调度。

## 8. 部署

部署前必须提供管理员密码：

```bash
CLICKHOUSE_ADMIN_PASSWORD='replace-with-a-strong-secret' ./scripts/deploy.sh
```

脚本会在创建基础设施前检查密码并计算 SHA-256，只把 hash 写入临时 manifest。Terraform 默认要求人工确认。CI 如需非交互执行，必须显式设置：

```bash
CLICKHOUSE_ADMIN_PASSWORD='...' AUTO_APPROVE=true ./scripts/deploy.sh
```

部署顺序：

1. 两阶段 `terraform apply`：先只建 AWS 基础设施（VPC、EKS、节点组、S3、IRSA），再建集群内资源。分两步是因为 kubernetes/helm provider 需要一个已存在的 EKS API 端点。
2. 安装 operator、监控，以及仅在存在 `local-nvme` 集群时才需要的 local-static-provisioner。
3. 对 `clickhouse_clusters` 中的**每个集群**依次执行：7 项前置校验 → 渲染 CHK/CHI 模板 → 按序 apply（namespace → 备份 → Keeper → 等 quorum → CHI）→ 等待 Pod → smoke test。
4. 最后应用一次共享的 Grafana dashboard。

前置校验会在 apply CHI **之前**拦住已知的失败模式：StorageClass 缺失或 `volumeBindingMode` 不对（会让 PVC 永久 Pending）、节点数不足 `shards × replicas`、占位符残留、Keeper 未达 quorum。

不要直接应用 `manifests/templates/` 下的模板；其中的占位符必须由部署流程渲染。

### 8.1 追加或移除一个集群

集群集合就是 `clickhouse_clusters` 这个 map，**追加一个集群只需增加一个 key**：

```hcl
clickhouse_clusters = {
  ebs = {
    storage_profile = "ebs"
    shards          = 1
    replicas        = 3
  }
  nvme = {
    storage_profile = "local-nvme"
    shards          = 1
    replicas        = 3
  }
}
```

然后重跑 `./scripts/deploy.sh`。已有集群不会被触碰——节点组按字符串 key 编址（`ck-<集群>-<AZ>`），不是按列表序号，所以增删任一集群都不会让其他集群的资源地址位移。

移除单个集群：

```bash
./scripts/teardown.sh --cluster nvme
```

它只删该集群的 CHI、Keeper、namespace、节点组和 StorageClass，并回收 `Retain` 策略遗留的 EBS 卷。完成后需把对应 key 从 `clickhouse_clusters` 中删除，否则下次 apply 会重建。

**2026-08-17 实测验证**（[验收记录](./docs/perf-results/multi-cluster-verify-20260817-summary.csv)）：在一套 EKS 上同时运行 `ebs`（gp3 3400 GiB）与 `nvme`（local NVMe 3436 GiB）两个 1×3 集群，复制在全部 6 个副本上生效；追加与移除集群时 `terraform plan` 在既有集群地址上均为**零变更**，且既有集群的 6 个 Pod UID 不变、重启次数为 0。

## 9. 验证与访问

```bash
kubectl -n clickhouse get chi,chk,pods
./scripts/smoke-test.sh
```

Smoke test 会验证 1×3 拓扑、ReplicatedMergeTree 写入、跨副本复制和 `system.replicas`。

ClickHouse 默认仅在集群内可用。临时访问：

```bash
kubectl -n clickhouse port-forward svc/clickhouse-ch 8123:8123
curl -u admin:yourpassword "http://localhost:8123/?query=SELECT+version()"
```

## 10. 监控

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
```

重点监控副本延迟、replication queue、磁盘使用率、merge backlog、查询延迟、CPU、内存和网络。仓库中的 dashboard ConfigMap 是基础入口，生产使用前应按实际指标名称和告警阈值补齐。

## 11. 备份与恢复

每日 CronJob 在 `02:00 UTC` 调用 `clickhouse-backup`，将单分片的一个完整副本上传到版本化、加密并阻断公有访问的 S3 bucket。

查看备份：

```bash
kubectl -n clickhouse get cronjob clickhouse-backup-daily
kubectl -n clickhouse get jobs
cd terraform && terraform output -raw backup_bucket
```

永久丢失本地 NVMe 节点时，Kubernetes 不会自动把 PVC 移到新节点。确认故障节点不会恢复且至少一个其他副本健康后执行：

```bash
CONFIRM_REPLICA_DATA_LOSS=yes \
  ./scripts/recover-local-replica.sh chi-ch-main-0-1
```

脚本拒绝删除 Ready Pod，只处理 `local-storage` PVC，并在清理旧 Pod/PVC/PV 时短暂停止 operator，随后恢复 operator 并等待新副本。Pod Ready 后仍需检查 `system.replicas` 队列归零。

改用 EBS 数据卷时不需要这个重灌流程：[2026-08-13 演练](./docs/ha-drill-report.md) 实测停止一个数据节点后，原卷在 111 秒内重新挂载到**同 AZ** 替换节点，数据零重建、服务中断 3 秒。前提是节点组绑定单一子网——gp3 卷是 AZ 绑定资源，若节点组跨多个子网，替换节点可能落到其他 AZ 而无法挂载。该结论来自受控的实例停止，未覆盖 AZ 级故障或卷本身损坏；卷损坏时恢复路径与本地盘相同。

**PDB 注意事项：** 不要为 ClickHouse Pod 手写 PodDisruptionBudget。Altinity operator 已为每个 cluster 自动创建（`maxUnavailable: 1`），额外添加选中同一批 Pod 的 PDB 会让它们**永久不可驱逐**——eviction API 拒绝被多个 PDB 覆盖的 Pod，导致 `kubectl drain`、节点滚动升级和 autoscaler 缩容全部无限期阻塞。该缺陷已于 2026-08-13 演练中发现并修复。

全体 ClickHouse 副本丢失时，优先从上游湖仓按分区重建；S3 ClickHouse 备份是缩短 RTO 的辅助恢复点，而不是权威数据事实来源。

## 12. 销毁

```bash
./scripts/teardown.sh
```

脚本先删除集群内资源，再销毁 EKS/VPC。S3 备份桶及其版本化、加密和公有访问阻断配置会被保留，并从 Terraform state 移除。脚本会打印准确桶名；确认备份不再需要后，必须人工删除全部对象版本和 bucket。

## 13. 适用边界与文档规则

当前非目标：

- 不部署数据湖仓、Glue Catalog、Kafka/MSK 或 Flink。
- 不实现 Cloud 与 OSS 双写、历史回填、CDC、去重或结果比对。
- 不提供公网负载均衡、TLS、认证代理或多租户隔离。
- 不提供自动分片、自动 local-PV 故障恢复或弹性 scale-out。
- 不把 ClickHouse 或备份桶定义为唯一 SoT。

`README.md` 与 `README.en.md` 是同步维护的中英文权威入口，章节编号和技术事实必须保持一致。`docs/` 下的调研、测试报告和历史实施计划属于支持材料，其权威级别和适用版本见 [docs/README.md](./docs/README.md)。
