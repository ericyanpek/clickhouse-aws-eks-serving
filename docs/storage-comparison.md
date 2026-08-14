# ClickHouse 本地 NVMe 与 EBS 并行对比方案

**中文** · [English](./storage-comparison.en.md)

> 状态：**历史文档。** 本文描述的专用部署脚本（`deploy-ebs-comparison.sh` 等）已随多集群改造删除——在新的 `clickhouse_clusters` map 下，同样的并行对比只需在 map 里声明两个集群（一个 `storage_profile = "ebs"`、一个 `local-nvme`）再跑 `./scripts/deploy.sh`，不再需要专用脚本。2026-08-11 的 1×2 EBS-only 实测结果见 [`storage-comparison-results.md`](./storage-comparison-results.md)，2026-08-12 的同轮选型实测见 [`storage-selection-report.md`](./storage-selection-report.md)。本文保留用于记录当时的方法与边界。
>
> 目标：保留现有 `i8g.4xlarge + local NVMe` 集群不变，在同一 EKS、Operator、Keeper、监控和压测节点上增加独立的 `r8g.4xlarge + gp3` 集群，以相同 ClickHouse 版本、拓扑、资源限制、数据集和查询比较存储性能与恢复模型。

## 1. 并行架构

```text
                         same EKS / Operator / Keeper
                                      |
                 +--------------------+--------------------+
                 |                                         |
       baseline CHI: ch                         comparison CHI: ch-ebs
       cluster: main                            cluster: mainebs
       3 x i8g.4xlarge                          3 x r8g.4xlarge
       16 vCPU / 128 GiB                        16 vCPU / 128 GiB
       local NVMe 3.75 TB                       gp3 3400 GiB
       local-storage                            clickhouse-ebs-gp3
                 |                                         |
                 +------------- same benchmark client -----+
```

`enable_ebs_comparison=false` 是默认值，因此现有节点池、CHI、PVC、服务和部署脚本行为保持不变。显式启用后只会新增：

- 3 个 `r8g.4xlarge` 节点，每 AZ 一个。
- 3 个 3400 GiB gp3 数据卷。
- `clickhouse-ebs-gp3` StorageClass。
- 独立 `ch-ebs` CHI、Service、PVC 和 PDB。

EBS 对照集群复用现有 Keeper 和系统组件，不复用 ClickHouse 数据卷或查询 Pod。

每个 gp3 卷仍是 AZ 级资源。节点故障时，EKS 节点组在原 AZ 补充节点后，Pod 可以重挂原 EBS 卷，不需要重灌完整副本；如果整个 AZ 不可用，该卷不能直接跨 AZ 挂载，服务先依靠另外两个副本，之后从副本、备份或湖仓重建。

## 2. 机型与 EBS 参数

根据 2026-08-11 在 `us-east-1` 调用 EC2 `DescribeInstanceTypes` 的结果：

| 项目 | i8g.4xlarge | r8g.4xlarge |
|---|---:|---:|
| vCPU | 16 | 16 |
| 内存 | 128 GiB | 128 GiB |
| 本地盘 | 1 × 3750 GB NVMe | 无 |
| EBS 基线 | 20,000 IOPS / 625 MB/s | 20,000 IOPS / 625 MB/s |
| EBS 峰值 | 40,000 IOPS / 1,250 MB/s | 40,000 IOPS / 1,250 MB/s |

选择 `r8g.4xlarge` 是为了保持 CPU 架构、vCPU 和内存一致，同时避免购买不用的 instance store。

首轮对比将 gp3 配置为 `40,000 IOPS / 1,250 MiB/s`，即 R8g.4xlarge 的 EBS 通道上限。这样测到的是“高配 EBS 与本地 NVMe”的架构差异，而不是 gp3 默认 `3,000 IOPS / 125 MiB/s` 导致的人为瓶颈。

建议第二轮将 EBS 调低到 `20,000 IOPS / 625 MiB/s`，评估基线带宽是否已经满足实际负载，并量化额外预置性能的价值。

注意：40,000 / 1,250 是实例 EBS 通道峰值，不是 R8g.4xlarge 的持续基线。卷侧预置到该值只提供性能余量，不能绕过实例侧限制；长时间测试必须观察 EC2 的 `EBSIOBalance%`、`EBSByteBalance%` 和 EBS 卷队列。若负载需要持续高于 20,000 IOPS / 625 MiB/s，应改测具有更高 EBS 基线的更大实例，而不是继续提高同一台 R8g.4xlarge 的 gp3 参数。

## 3. 测试口径

测试脚本使用项目已有方法：

1. ClickBench `hits`：99,997,497 行、105 列，压缩后约 13.45 GiB；脚本显式锁定列类型、分区键、排序键和采样键，不再运行时推断 schema。
2. 2026-07-05 历史 ClickBench 43 条查询，每条运行 3 次取最优；下载后校验 SHA-256 `a7d6673357348ee9680443216b6f26f30d1dce9f313b419d38502417b2c2a219`。
3. `warm`：保持现有 best-of-3 热运行口径。
4. `direct_io`：设置 `min_bytes_to_use_direct_io=1`，减少 page cache 掩盖存储差异。
5. QPS：点查、过滤聚合和空查询使用并发 8、12 秒；全表聚合使用并发 1、2、4、8、16。
6. 强制 ClickHouse `25.3.14.14`、历史对比的 2 副本和独立 `c7g.2xlarge` 压测节点；记录 active parts/marks，防止物理布局差异被误判为存储差异。
7. 记录数据加载、副本追平时间，以及节点、PVC、PV 和 StorageClass 元数据。

输出目录为 `results/storage-comparison/<UTC timestamp>/`，主要文件是：

- `clickbench.csv`
- `load-seconds.csv`（分别记录单副本插入完成和三副本全部追平时间）
- `disks-local_nvme.tsv` / `disks-ebs_gp3.tsv`
- `qps-*.txt`
- `qps-queries.sql`
- `clickbench-queries.sql` / `clickbench-queries.sha256`
- `benchmark-client.tsv`
- `parts-local_nvme.tsv` / `parts-ebs_gp3.tsv`
- `nodes.txt`
- `pods-pvcs.txt`
- `pvs.txt`
- `storage-classes.yaml`

## 4. 部署与测试

先部署并验证现有本地 NVMe 基线，再增加 EBS 对照：

```bash
CLICKHOUSE_ADMIN_PASSWORD='...' ./scripts/deploy.sh

CLICKHOUSE_ADMIN_PASSWORD='...' \
  CONFIRM_CREATE_EBS_COMPARISON=yes \
  ./scripts/deploy-ebs-comparison.sh

CLICKHOUSE_ADMIN_PASSWORD='...' \
  ./scripts/run-storage-comparison.sh
```

自动化或已审查 Terraform plan 后才应设置 `AUTO_APPROVE=true`。EBS add-on 会创建持续计费的 EC2 和 EBS 资源。

EBS 集群存在期间，必须在 `terraform/terraform.tfvars` 中保持：

```hcl
enable_ebs_comparison = true
```

否则后续不带命令行覆盖参数的 `terraform apply` 会移除 EBS 节点池和 StorageClass。

如果只需要复用 2026-07-05 的历史 1×2 NVMe 实测结果，不创建新的 i8g 节点，请在 `terraform/terraform.tfvars` 中设置：

```hcl
enable_local_nvme      = false
enable_ebs_comparison  = true
ebs_comparison_zones   = ["us-east-1a", "us-east-1b"]
public_access_cidrs    = ["YOUR_CURRENT_PUBLIC_IP/32"]
```

然后只部署并测试 1×2 EBS：

```bash
CLICKHOUSE_ADMIN_PASSWORD='...' \
  CONFIRM_CREATE_EBS_ONLY_TEST=yes \
  ./scripts/deploy-ebs-only.sh

COMPARE_LOCAL=false \
  CLICKHOUSE_ADMIN_PASSWORD='...' \
  ./scripts/run-storage-comparison.sh
```

该模式仍会创建新的 EKS、Keeper、system 和 benchmark 节点，但不会创建 i8g、本地 NVMe CHI 或本地盘数据。测试完成后可销毁整个临时环境：

```bash
CONFIRM_DELETE_EBS_ONLY_TEST=yes \
  ./scripts/teardown-ebs-only.sh
```

测试后只删除 EBS add-on：

```bash
CONFIRM_DELETE_EBS_COMPARISON=yes \
  ./scripts/teardown-ebs-comparison.sh
```

现有 `ch` 本地 NVMe 集群不会被该清理脚本删除。

## 5. 结果解释

重点比较：

| 维度 | 主要指标 |
|---|---|
| 热查询 | 43 查询 best-of-3、p50、p90、总耗时 |
| 存储敏感查询 | direct I/O 与 warm 的延迟差异 |
| 并发读取 | 三类查询在 c=8 的 QPS；全表查询在 c=1/2/4/8/16 的扩展 |
| 摄入 | S3 加载耗时、复制追平时间 |
| 后台压力 | merge queue、replication queue、CPU iowait |
| 恢复 | Pod 重启与节点替换后的 Ready 时间、复制队列 |
| 成本 | EC2、EBS 容量、预置 IOPS/吞吐和运维成本 |

ClickBench 数据只有约 13.45 GiB，小于 110 GiB Pod 内存，因此 warm 结果可能主要反映 CPU 和 page cache。存储选型不能只看 warm 结果，必须同时看 direct I/O、较大数据集下的 merge/insert 压力和节点级恢复。

2026-08-11 的实测表明 warm 43 查询两种方案基本同档；过滤聚合因历史与当前 active-parts 布局不同而不可直接比较。完整限制与 CloudWatch 证据见 [`storage-comparison-results.md`](./storage-comparison-results.md)。

### 5.1 节点恢复对比

Pod 删除后在原节点重启不能证明 EBS 的故障漂移能力，应把节点恢复作为独立测试：

1. 持续运行低并发查询，记录错误率和可用副本数。
2. 记录目标 Pod、PVC、节点和 AZ；确认 EBS 节点组 `max_size=2` 且该 AZ 有 R8g 配额。
3. 对一个 EBS 节点执行受控 `kubectl drain`。PDB 保留另外两个副本，Cluster Autoscaler 应在同 AZ 增加节点，原 PVC 重挂后 Pod 恢复。
4. 记录从驱逐开始到 Pod Ready、ClickHouse 可查询、replication queue 归零的三个时间点。
5. 本地 NVMe 对照会因 local PV 节点亲和性停留在原节点；永久节点丢失后需要 `recover-local-replica.sh` 删除失效 local PV 并从健康副本重灌。

受控 drain 是偏乐观的恢复测试。真实 EC2 主机丢失还会包含节点失联判定和 EBS 强制分离时间；如需模拟，必须另行审批终止实例，并确认不会同时影响第二个副本。

## 6. 决策建议

- 如果调优后的 gp3 满足延迟和 merge SLA，优先 EBS，以获得更短、更自动化的节点恢复。
- 如果 EBS 通道持续饱和、merge backlog 增长或冷扫描明显落后，再选择本地 NVMe。
- 如果只有 warm 查询更快，但 direct I/O、摄入和恢复没有达到预期，不应仅凭平均查询延迟选择本地盘。
- EBS 改善的是节点级故障后的同 AZ 重挂时间，不等于 EBS 卷跨 AZ 漂移；跨 AZ 可用性仍由 3 副本承担。
- 本地 NVMe 和 EBS 都不改变湖仓是唯一 SoT、ClickHouse 是可重建 OLAP 加速层的项目定位。
