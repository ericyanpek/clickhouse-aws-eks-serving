# ClickHouse on Amazon EKS OLAP 加速层

**中文** · [English](./README.en.md)

> **架构前提:** 数据湖仓是唯一权威数据事实来源（Source of Truth, SoT），保存完整历史并支持重放。ClickHouse 只保存从湖仓派生、可重建的 MergeTree 数据，用作低延迟 OLAP / BI 查询加速层；它不是主数据存储，也不是唯一事实来源。
>
> 本仓库只部署 ClickHouse on EKS，不创建上游湖仓，也不实现 Kafka/Flink 摄入作业。采用本方案前，必须已经有可重放的数据湖仓和对应的批量或流式同步链路。仓库创建的 S3 bucket 仅用于 ClickHouse 备份/灾备，**不是湖仓 SoT**。

## 1. 项目定位与价值

本项目提供一套可评审、可执行的 Terraform + Kubernetes IaC，在自有 AWS 账号中部署：

- ClickHouse：**1 分片 × 3 副本**，每副本独占一个跨 AZ 的 `i8g.4xlarge` 节点和本地 NVMe。
- ClickHouse Keeper：3 节点跨 AZ quorum，数据存放在持久化 EBS。
- Altinity ClickHouse Operator `0.27.1`。
- Prometheus、Grafana、每日 S3 备份和 IRSA 权限。
- NVMe 初始化、部署、验证、节点丢失恢复和有序销毁脚本。

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
| 数据存储 | 每副本约 3.4 TiB 本地 NVMe，`ReplicatedMergeTree` |
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

### 4.3 本地 NVMe

本地 NVMe 提供高 IO，但节点终止后数据永久丢失，local PV 也不会自动漂移。该取舍只在 ClickHouse 数据可从湖仓重建时成立。若 ClickHouse 是唯一数据源，应改用更持久的存储设计，并重新评估本仓库的恢复模型。

仓库同时提供默认关闭、不会替换现有集群的 [R8g + 高性能 gp3 并行对比方案](./docs/storage-comparison.md)，也支持不创建 i8g 的 EBS-only 模式复用历史 NVMe 结果。2026-08-11 的 [EBS 实测](./docs/storage-comparison-results.md) 显示小型 warm ClickBench 与 NVMe 基本同档，并明确记录了 direct-I/O 和 active-parts 可比性边界。

### 4.4 S3 备份

`clickhouse-backup` 保存的是 ClickHouse 恢复点，用于缩短灾难恢复时间。备份桶不替代湖仓，默认 teardown 后继续保留，并从 Terraform state 移除。

## 5. 与其他方案的关系

- **ClickHouse Cloud on AWS**：原厂托管、轻运维、弹性更强，通常是没有自管硬需求时的优先选择。
- **Altinity Terraform EKS Blueprint**：本项目复用其 VPC/EKS/节点组和 operator 基础设施层，但用自有 CHI/CHK 清单替换其封装的集群层。
- **AWS data-on-eks**：更偏完整数据平台样板；本项目聚焦固定 1×3、专属节点、本地 NVMe 和较少依赖。

设计依据、实测报告和历史材料的状态见 [文档索引](./docs/README.md)。

## 6. 前置条件与成本

需要：

- Terraform `>= 1.5`
- AWS CLI 和可用凭证
- `kubectl`、Helm 3
- EKS、VPC/EC2、IAM、S3 权限
- 目标区域内至少 3 台 `i8g.4xlarge` 的配额和容量
- 已存在的数据湖仓、schema 管理和可重放摄入链路

该部署持续运行时成本显著，包括 3 台 i8g 数据节点、3 台 Keeper 节点、3 台 system 节点、1 台 benchmark 节点、NAT Gateway 和 EKS 控制面。价格随区域和时间变化，apply 前必须使用 AWS Pricing Calculator 和 Service Quotas 核实，不应把仓库中的历史估算当报价。

## 7. 配置

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

至少检查：

```hcl
region             = "us-east-1"
availability_zones = ["us-east-1b", "us-east-1c", "us-east-1d"]
clickhouse_zones    = ["us-east-1b", "us-east-1c", "us-east-1d"]

backup_bucket_name = ""
public_access_cidrs = ["203.0.113.0/24"]
```

`availability_zones` 和 `clickhouse_zones` 必须是同一区域内三个真实、不同的 AZ。`public_access_cidrs` 默认值会开放 EKS 公网 API，生产环境必须收紧。

资源值按 `i8g.4xlarge` 定尺。切换实例类型时必须同步调整 [ClickHouse manifest](./manifests/20-clickhouse-chi.yaml) 中的 CPU、内存和 PVC 容量。

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

1. 创建 VPC、EKS、节点组、S3 备份桶和 IRSA。
2. 安装 operator、监控和 local-static-provisioner。
3. 用 DaemonSet 格式化并挂载 ClickHouse 节点的 instance-store NVMe。
4. 按 namespace、备份配置、Keeper、ClickHouse、Grafana dashboard 的顺序应用 manifest。

不要直接应用仓库中的 CHI；其中的 `REPLACE_WITH_ADMIN_SHA256` 必须由部署流程替换。

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
