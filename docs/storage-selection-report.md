# ClickHouse 本地 NVMe 与 EBS 存储选型实验报告

**中文** · [English](./storage-selection-report.en.md)

> 状态：**2026-08-12 单轮性能测试已完成查询、并发、摄入、CloudWatch、merge 计时与 merge 窗口设备级 I/O 取证；重复轮次、稳态和 HA 仍待完成（PARTIAL）**
> 项目边界：上游数据湖仓保存唯一权威数据事实（SoT）；ClickHouse 是可重建的 OLAP 加速层。本报告选择的是加速层的存储、性能、恢复和成本模型，不改变数据权威边界。
> 报告原则：只有满足本文硬件、拓扑、数据、查询和观测合同的同轮结果才能进入最终选型。
> 当前范围：本轮先形成存储性能证据；HA、PDB 归一化和恢复演练是独立后续 TODO。不得从查询、摄入或 merge 性能推断 HA 能力或恢复 RTO。
> 实际拓扑披露：2026-08-12 因 `us-east-1b` 和 `us-east-1c` 的 `i8g.4xlarge` 容量不足，本地 NVMe 性能阶段使用 `us-east-1a` 内 2 个节点，逻辑拓扑仍为 1 shard × 2 replicas；EBS 使用 `us-east-1a` + `us-east-1b`。本地读取、查询和设备 I/O 结果可用于存储性能比较，但复制写入、跨 AZ 延迟和 HA 不具备 Apple-to-Apple 可比性。

## 1. AWS SA 决策框架

AWS 解决方案架构师视角下，选型不能只比较单条查询延迟。最终建议按以下六个维度评审：

| 维度 | 需要回答的问题 | 决策证据 |
|---|---|---|
| 业务与 SLA | 目标查询延迟、并发、写入速率、RTO 和可接受错误窗口是什么？ | p50/p95/p99、QPS、摄入速率、恢复时间、错误数 |
| 性能上限 | 瓶颈在 CPU、内存、块设备还是 EBS 实例通道？ | CPU、iowait、磁盘吞吐/IOPS/延迟、EBS balance、队列深度 |
| 弹性与恢复 | Pod、节点和 AZ 故障下，服务与副本如何恢复？ | Pod 删除、节点丢失、EBS 重挂、本地盘重灌的分段 RTO |
| 数据耐久性 | 节点永久丢失是否会造成权威数据丢失？ | 湖仓重放、健康副本拉取、备份恢复路径 |
| 运维复杂度 | 哪种方案更容易自动化、扩容、升级和处理故障？ | 人工步骤、Runbook、告警、恢复演练成功率 |
| 成本效率 | 为每单位吞吐、扫描量和可用性付出多少？ | 月成本、每十亿行摄入成本、每 TiB 扫描成本、每百万查询成本 |

决策顺序：

1. 先淘汰不满足硬性 SLA、容量或恢复目标的方案。
2. 再比较满足 SLA 的方案的单位工作量成本和运维风险。
3. 若性能差异落在重复测试波动范围内，优先恢复更简单、风险更低的 EBS。
4. 只有在确认 EBS 通道是持续瓶颈，且本地 NVMe 的收益足以覆盖重灌与运维成本时，才选择本地盘。

## 2. 官方数据源与确定性 10× 扩展

### 2.1 官方 ClickBench 基线

本实验的**主数据集是官方 ClickBench 100M**，即 ClickHouse 发布的 `hits` 兼容数据和官方查询集：

- 官方仓库：https://github.com/ClickHouse/ClickBench
- 官方 100M Parquet：https://datasets.clickhouse.com/hits_compatible/hits.parquet
- 官方结果页：https://benchmark.clickhouse.com/
- 官方硬件结果页：https://benchmark.clickhouse.com/hardware/
- 官方 ClickHouse DDL：https://github.com/ClickHouse/ClickBench/blob/main/clickhouse/create.sql
- 官方 43 条查询：https://github.com/ClickHouse/ClickBench/blob/main/clickhouse/queries.sql
- `clickhouse-benchmark` 官方文档：https://clickhouse.com/docs/operations/utilities/clickhouse-benchmark

基线数据为 `hits` 表的 99,997,497 行、105 列。查询文件固定到项目已验证的提交，并校验 SHA-256，防止上游变化破坏可重复性。

### 2.2 项目生成的确定性 10× 数据

10× 阶段是**项目派生压力数据，不是 ClickHouse 官方另行发布的 10× ClickBench 数据集**：

- 将同一官方 Parquet 数据确定性装载 10 次，目标总行数为 999,974,970。
- 每个副本批次只对 `WatchID`、`UserID` 和 `FUniqID` 加固定偏移，避免标识符完全重复。
- 日期、事件属性和其余列保持官方数据分布；相同脚本、偏移和批次顺序用于 NVMe 与 EBS。
- 该方法适合制造超出内存的扫描、摄入、parts 和 merge 压力，但不代表十周独立生产流量，也不能用于推断真实数据增长后的压缩率或基数变化。

最终报告必须分别展示官方 1× 与派生 10× 结果，不得混合汇总。

### 2.3 公网装载与存储计时边界

当前装载路径通过 `url(...)` 从 ClickHouse 公网数据集顺序执行 NVMe 和 EBS 测试。端到端耗时同时包含：

- 公网下载、远端服务抖动和中间缓存命中差异。
- Parquet 解压、解码、类型转换和 ClickHouse INSERT CPU。
- 本地数据卷写入、WAL/parts 生成、复制传输和副本追平。

因此，顺序公网装载的 `insert_seconds` 和 `replicas_ready_seconds` 只能标记为**端到端摄入结果**，不能直接解释为 NVMe 或 EBS 的纯存储性能。最终报告必须把以下证据分开：

1. 下载/解码路径：源读取字节、下载时间、解码 CPU 时间、执行顺序和失败重试。
2. ClickHouse 存储路径：块设备写入 MiB/s、IOPS、await、utilization、parts/merge 吞吐和复制追平。
3. 存储隔离测试：将同一不可变数据预置到等价的同区域来源，交替执行两侧顺序并单独记录写入阶段；若未完成，该栏必须写 `NOT ISOLATED`，不得给出“纯存储摄入更快”的结论。

## 3. 硬件与拓扑合同

| 项目 | 本地 NVMe | EBS gp3 |
|---|---|---|
| 数据节点 | 2 × `i8g.4xlarge` | 2 × `r8g.4xlarge` |
| CPU / 内存 | 16 vCPU / 128 GiB | 16 vCPU / 128 GiB |
| ClickHouse Pod | request 14 vCPU / 110 GiB；memory limit 110 GiB | 完全相同 |
| 目标拓扑合同 | 1 shard × 2 replicas，跨 2 个 AZ | 完全相同 |
| 2026-08-12 性能阶段实际拓扑 | 1 shard × 2 replicas；2 个节点均在 `us-east-1a` | 1 shard × 2 replicas；`us-east-1a` + `us-east-1b` |
| ClickHouse | `25.3.14.14` | 完全相同 |
| 数据卷 | `local-storage`，PVC 3400 Gi | gp3，PVC 3400 Gi |
| EBS 首轮配置 | 不适用 | 40,000 IOPS / 1,250 MiB/s |
| 实例 EBS 通道 | 非 ClickHouse 数据路径 | 基线 5,000 Mbps（625 MB/s = 596.05 MiB/s）/ 20k IOPS；最大 10,000 Mbps（1,250 MB/s = 1,192.09 MiB/s）/ 40k IOPS |
| 查询入口 | 独立 ClusterIP | 独立 ClusterIP |
| 压测端 | 独立 `c7g.2xlarge` benchmark 节点 | 同一节点、同一客户端镜像 |
| Operator / Keeper | 同一 EKS、Operator 和 Keeper | 同一共享基础设施 |

测试合同还要求：

- 两侧使用相同表 DDL、排序键、分区键、采样键、用户设置和副本数。
- 测试前记录 AMI、内核、文件系统、挂载参数、ClickHouse 镜像 digest、节点 allocatable 和 DaemonSet 开销。
- 任何一侧发生 CPU throttling、内存压力、网络瓶颈、异常副本延迟或后台任务不一致，该轮结果作废或单独标记。
- HA 测试前必须统一两侧 PDB；当前测试清单中本地盘 `minAvailable: 1`、EBS `minAvailable: 2`，不修正则受控 drain 不具备同口径。
- 正式 1×3 生产拓扑的容量和 HA 结论需另行验证；1×2 是存储介质 A/B 合同。
- 单位口径：AWS 实例 EBS 通道按十进制 MB/s 标称，gp3 预置吞吐按 MiB/s 标称，两者不可直接混用。本报告统一换算为 MiB/s 后再比较。
- **突发限制（决策相关）：** `r8g.4xlarge` 的 EBS 通道基线与最大值不相等，因此属于突发型规格——每 24 小时最多只能维持 1,192.09 MiB/s / 40k IOPS 的最大值 30 分钟，随后回落到 596.05 MiB/s / 20k IOPS 基线。`r8g.8xlarge` 是该系列中基线等于最大值的最小规格。凡是持续超过 30 分钟的负载（本轮 merge 在两个副本上分别持续 55 分钟和 82 分钟），都必须按 596.05 MiB/s 基线而不是最大值来规划。

### 3.1 2026-08-12 实际拓扑与可比性边界

2026-08-12，`us-east-1b` 和 `us-east-1c` 无法提供所需的 `i8g.4xlarge` 容量。为保留已经就绪的基础设施并继续性能阶段，本地 NVMe 使用 `us-east-1a` 内 2 个 `i8g.4xlarge` 节点；EBS 继续使用分布在 `us-east-1a` 和 `us-east-1b` 的 2 个 `r8g.4xlarge` 节点。两侧 ClickHouse 逻辑拓扑均保持 1 shard × 2 replicas。

该实际拓扑支持以下范围的比较：

- 本地读取、ClickBench 查询和明确归属到 ClickHouse 数据盘的设备 I/O，可在满足其余测试合同后进行比较。
- 单副本本地写入路径可作为辅助证据，但包含副本复制完成时间的端到端写入结果同时受到同 AZ 与跨 AZ 网络路径差异影响。
- 复制写入、复制追平和跨 AZ 延迟不具备 Apple-to-Apple 可比性，不得据此判定 NVMe 或 EBS 的存储写入优势。
- Pod、节点或 AZ 故障下的 HA 与恢复能力不具备 Apple-to-Apple 可比性，继续保留为 TODO；执行前必须取得对称 AZ 拓扑并统一 PDB、故障方法和负载。

## 4. 实验控制与执行规则

1. 测试顺序在不同重复轮次中交替使用 NVMe-first 与 EBS-first，减少时间和缓存偏差。
2. 每个有效阶段至少运行 3 轮；报告中同时给出中位数、最差轮次和变异系数。
3. 每阶段前校验行数、`SHOW CREATE TABLE`、查询 SHA-256、active parts、marks、复制队列和副本健康。
4. warm、direct I/O 和冷缓存结果分开报告；不得用 warm 结果代表存储性能。
5. merge 测试前使用相同批次装载并暂停后台 merge；随后在相同 parts 起点执行 `OPTIMIZE ... FINAL`。
6. 性能流量只从 EKS 内专用 benchmark 节点访问 ClusterIP；本地工作站只负责控制。
7. 保存全部原始日志、系统表快照、节点/PV/PVC/VolumeAttachment 信息和 UTC 时间戳。
8. 在同一阶段中不得修改实例类型、ClickHouse 设置、EBS 参数、查询或数据布局。
9. 公网装载必须记录执行顺序，并与存储隔离计时分栏；不得用先后执行的两个端到端下载结果计算存储介质差值。
10. HA 与恢复结果只来自完成 PDB 归一化后的独立故障实验，不得从性能阶段外推。

## 5. 测试阶段

| 阶段 | 工作负载 | 目的 | 主要输出 |
|---|---|---|---|
| P0 预检 | 空载与基础设施快照 | 证明两侧合同一致 | 配置、版本、节点、parts、磁盘基线 |
| P1 官方 1× | 43 queries，warm + direct I/O | 兼容历史结果并识别缓存影响 | 每查询延迟、总耗时、p50/p95/p99 |
| P2 1× 并发 | 点查、过滤聚合、全表聚合，c=1/2/4/8/16 | 找到 CPU、服务和存储饱和点 | QPS、尾延迟、错误率、扩展效率 |
| P3a 确定性 10× 端到端摄入 | 通过公网 `url(...)` 顺序装载 10 个固定批次 | 测量下载、解码、写入和复制的整体路径 | 端到端 rows/s、单批耗时、复制延迟、执行顺序 |
| P3b 存储隔离摄入 | 同一数据预置到等价来源，交替顺序执行 | 分离下载/解码污染，比较 ClickHouse 存储路径 | 设备写 MiB/s/IOPS/await、parts 和复制追平 |
| P4 确定性 10× 查询 | 43 queries 与并发阶梯 | 让工作集超出内存并暴露存储差异 | warm/direct I/O 延迟、QPS、扫描吞吐 |
| P5 merge 竞争 | c=4 全表查询期间执行 `OPTIMIZE FINAL` | 模拟查询与后台维护竞争 | merge 时间、QPS 降幅、尾延迟、iowait |
| P6 EBS 参数阶梯 | 40k/1250、20k/1250、20k/1000、20k/625、3k/125 | 先分离 IOPS 与吞吐影响，再找到 gp3 成本与性能拐点 | SLA、卷/实例限额利用率、成本差 |
| P7 Pod 恢复（后续 TODO） | PDB 归一化后，持续查询时删除一个副本 Pod | Apple-to-Apple 比较 Pod 自愈 | 错误数、服务连续性、Ready/可查询时间 |
| P8 节点故障（后续 TODO） | PDB 归一化后，受控失去一个数据节点 | 比较 EBS 重挂与 NVMe 重灌 | 分段 RTO、降级 QPS、复制恢复流量 |
| P9 稳态耐久 | 目标摄入 + 查询 + merge，至少 2 小时 | 发现短测试看不到的队列与 credits 问题 | SLA 达标率、积压、balance、热稳定性 |

P7/P8 不属于当前性能结论。执行前必须统一 PDB、故障注入方法和持续查询负载。P8 还必须将两种恢复模型如实拆开：EBS 测同 AZ 新节点重挂原卷；NVMe 测从健康副本重建，必要时再测从湖仓重灌。两者不是相同动作，但都应从“节点不可服务”计时到“恢复完整冗余”。

## 6. 指标与观测

| 类别 | 必采指标 |
|---|---|
| 查询 | p50/p95/p99、最大延迟、QPS、超时、错误数、read_rows、read_bytes |
| 下载/解码 | 源读取字节、下载时间、解码 CPU、执行顺序、缓存状态和重试 |
| 端到端摄入 | rows/s、每批 insert 时间、复制队列清空时间、parts 生成速率 |
| 存储隔离写入 | 块设备写 MiB/s、IOPS、await、utilization、parts/merge 吞吐 |
| merge | merge wall time、bytes/s、parts 前后数量、查询 QPS/尾延迟降幅 |
| 主机 | CPU 使用率、steal、load、内存、page cache、major faults、iowait |
| 块设备 | 读写 MiB/s、IOPS、平均请求大小、await、utilization、queue depth |
| EBS | VolumeRead/WriteBytes、VolumeRead/WriteOps、VolumeQueueLength、EBSByteBalance%、EBSIOBalance% |
| ClickHouse | `system.query_log`、`system.parts`、`system.merges`、`system.replicas`、异步指标 |
| 恢复 | 检测、调度、挂载/建盘、Pod Ready、首次查询成功、复制追平、完整冗余 |
| 质量 | 每轮配置哈希、查询哈希、行数、parts/marks、异常与作废原因 |

结果必须同时报告绝对值和相对差异，并附置信区间或至少报告多轮离散程度。没有读写量和资源利用率支撑的单一延迟数字不能进入选型结论。

## 7. 成本模型

以下价格来自 2026-08-12 AWS Price List API，区域为 `us-east-1`，Linux On-Demand，按 730 小时/月估算。仅计算 ClickHouse 数据节点与数据卷；两侧相同的根卷、EKS、Keeper、监控、备份和数据传输未计入，因此适合比较增量差异，不是完整账单。

| 成本项 | 本地 NVMe | EBS gp3 |
|---|---:|---:|
| EC2 每节点小时价 | $1.37280 | $0.94256 |
| 数据节点数 | 2 | 2 |
| 数据节点计算费/月 | $2,004.29 | $1,376.14 |
| 数据卷容量费/月 | 实例存储已包含 | $544.00 |
| gp3 额外 IOPS 费/月 | 不适用 | $370.00 |
| gp3 额外吞吐费/月 | 不适用 | $90.00 |
| 两节点比较口径合计/月 | **$2,004.29** | **$2,380.14** |
| EBS 相对本地盘 | 基线 | **+$375.85 / +18.75%** |
| 目标 1×3 线性外推/月 | $3,006.43 | $3,570.21 |
| 备份 / S3 / 数据传输 | 未纳入 | 未纳入 |
| 共享 EKS、Keeper、监控 | 未纳入 | 未纳入 |
| 估算运维工时/月 | `PENDING` | `PENDING` |

必须计算：

```text
月基础设施成本 = EC2 + EBS 容量 + EBS IOPS + EBS 吞吐 + 备份/传输 + 共享成本分摊
每十亿行摄入成本 = 测试窗口成本 / 摄入行数 × 1,000,000,000
每 TiB 扫描成本 = 测试窗口成本 / 扫描 TiB
每百万成功查询成本 = 测试窗口成本 / 成功查询数 × 1,000,000
故障恢复风险成本 = 故障频率假设 × 降级时长 × 业务影响单价
```

gp3 当前单卷成本为：3400 GiB 容量 $272/月、额外 37k IOPS $185/月、额外 1125 MiB/s $45/月。若只把 IOPS 降到 20k 并保持 1250 MiB/s，两节点比较口径约为 $2,180.14/月，相对本地盘约 +8.77%；这比直接降吞吐更符合本轮观测。后续仍需给出 1 年和 3 年承诺折扣敏感性；承诺折扣不能掩盖 EBS 预置性能费用或 NVMe 恢复运维成本。

## 8. 选型边界

### 8.1 优先选择 EBS

当以下条件全部成立时，EBS 是默认建议：

- 在目标稳态工作负载下满足查询、摄入、merge 和恢复 SLA。
- EBS 卷与实例通道没有持续饱和，或可通过合理的 gp3 参数/实例规格解决。
- EBS 相对 NVMe 的单位工作量成本差在业务可接受阈值内：`PENDING`。
- 节点故障后重挂原卷显著缩短恢复完整冗余的时间，并减少人工步骤。

### 8.2 选择本地 NVMe

只有满足以下证据链时，才推荐本地 NVMe：

- 10× 与稳态阶段证明瓶颈确实是 EBS 存储路径，而不是 CPU、内存、parts 布局或客户端。
- 在已合理调优的 EBS 方案上仍无法满足 SLA，或达到 SLA 的 EBS 成本明显更高。
- NVMe 的收益跨多轮稳定，并超过预先定义的实质性阈值：延迟/QPS `PENDING`，单位成本 `PENDING`。
- 业务接受节点丢失后的副本重建窗口，且健康副本、湖仓重放和备份 Runbook 已演练。

### 8.3 证据不足以支持的结论

- 官方 1× warm ClickBench 相同，不能证明存储等价。
- 单次 direct I/O 更快，不能单独证明生产收益。
- EBS 未达到 40k IOPS / 1250 MiB/s，不能直接证明应降到默认 gp3。
- 顺序公网装载的端到端摄入更快，不能证明对应存储介质写入更快。
- Pod 原节点重启成功，不能代表节点故障恢复。
- 查询、摄入或 merge 性能更好，不能推断 HA 更好或恢复 RTO 更短。
- 本地盘可从副本恢复，不能替代湖仓 SoT 和备份策略。
- merge 期间头 300s 的并发查询 QPS 更高，不能推断 merge 会更早完成——本轮 EBS 正是"前 300s QPS 略优、整体晚 48.0% 完成"。
- `system.part_log.read_bytes` 是未压缩逻辑字节，不能当作设备字节用于计算存储带宽或判断是否打满预置吞吐。

## 9. 限制与有效性威胁

1. `i8g.4xlarge` 与 `r8g.4xlarge` 的 CPU/内存规格相同，但实例实现和价格不完全相同，测试不是只替换磁盘的实验室硬件。
2. 官方 1× 数据可进入 110 GiB 内存，warm 查询主要反映 CPU、执行引擎和 page cache。
3. 确定性 10× 重复数据分布，只扩大行数和部分标识符空间，不模拟自然业务增长。
4. 顺序公网下载会引入网络、缓存和远端服务差异；未完成 P3b 时不存在可用的纯存储摄入时延结论。
5. `OPTIMIZE FINAL` 是可重复的 merge 压力手段，不等价于所有生产后台 merge 模式。
6. 1×2 A/B 拓扑不等于项目目标 1×3；生产成本、降级容量和故障容忍度需外推后再验证。
7. 2026-08-12 性能阶段中，本地 NVMe 的 2 个节点同处 `us-east-1a`，EBS 节点分布在 `us-east-1a` 和 `us-east-1b`。本地读/查询和设备 I/O 可比较，但复制写入、跨 AZ 延迟与 HA 不可 Apple-to-Apple 比较。
8. EBS 是 AZ 级资源；同 AZ 重挂不代表跨 AZ 卷漂移。
9. NVMe 重建依赖健康副本、网络和湖仓可用性；结果受数据规模与 parts 结构影响。
10. HA/PDB 归一化与恢复实验尚未完成，性能结果不得作为可用性证据。
11. 共享 Keeper、EKS 网络和 benchmark 节点可能形成共同瓶颈，必须通过观测排除。
12. AWS 价格、实例能力和服务限额会变化，最终报告必须记录查询日期、区域和账户配额。
13. merge 重试的编排在 EBS 侧运行途中中断（操作者 SSM 隧道断开，runner 与压测客户端进程随之被杀），因此 runner 始终没有写出 `merge-final.csv` 的 EBS 行，也没有写出 `parts-after-merge-ebs_gp3.tsv`。ClickHouse 服务端不受影响并正常完成了 merge，上述两项证据是事后从服务端状态补采的。**采集时点不同必须如实标注：** 本地侧 parts 快照由 runner 在 merge 结束时写出，EBS 侧由人工于 2026-08-13 事后以相同查询补采。第 10.2 / 10.4 节的时间比较统一采用 `part_log` 口径以规避这一差异。
14. 计时基准不可混用：本地 `optimize_seconds` = 3,346s 是 runner 墙钟（包含 `SYSTEM START MERGES` 与 `OPTIMIZE FINAL` 的外层包装），而 `part_log` 口径为 3,321s，两者相差 25s。EBS 侧不存在 runner 墙钟值。因此正式对比只使用双侧同源的 `part_log` 口径（4,916 对 3,321，+48.0%）；把 4,916 与 3,346 相比会得到虚高的 +46.9%，属于跨基准比较，不得发布。
15. 本地侧 `OPTIMIZE ... ON CLUSTER ... FINAL` 返回时副本 0 为 1 个 active part、副本 1 仍有 13 个，而 EBS 侧两个副本均已收敛到 1 个。因此本地 span 偏向发起副本、并非"双副本收敛"时间，真实同口径差距应略大于 48.0%。后续有效对比必须要求两侧均收敛到 1/1。
16. `system.part_log` 中存在大量 `error=234`（`NO_REPLICA_HAS_PART`）行：EBS 侧 1,978 行中有 1,473 行，本地侧 1,889 行中有 1,377 行。这些是副本队列的拉取尝试在竞争中输给本地 merge 的记录，两侧对称出现且属正常现象，不是失败的 merge；但它们会虚增事件计数，因此任何 `part_log` 聚合都必须先按 `error=0` 过滤。

## 10. 2026-08-12 单轮结果（PARTIAL）

> 原始运行目录：`results/storage-selection/20260812T052520Z`；merge 竞争重试与设备级 I/O 取证位于 `results/storage-selection-merge-retry/20260812T075959Z`。可提交的语言无关摘要见 [`perf-results/storage-selection-20260812-summary.csv`](./perf-results/storage-selection-20260812-summary.csv)。本轮为单轮结果；重复轮次、稳态和 HA 未完成。以下判断均受第 3.1 节实际 AZ 拓扑限制，merge 计时另受第 9 节第 13–16 条限制。

### 10.1 有效性检查

| 检查项 | 本地 NVMe | EBS gp3 | 状态 |
|---|---|---|---|
| 配置合同一致 | 16 vCPU / 128 GiB；Pod 14 vCPU / 110 GiB；CH 25.3.14.14 | 相同 | PASS：实例家族和存储介质按设计不同 |
| 1× / 10× 行数一致 | 99,997,497 / 999,974,970 | 相同 | PASS；旧 `dataset-*.tsv` 曾把 parts 数误标为 rows，脚本已修正 |
| DDL 与查询哈希一致 | 105 列与键校验通过 | 相同 | PASS；43-query 文件 SHA-256 固定 |
| parts / marks 可比 | 1× 289 parts / 12,662 marks；10× 2,885 / 126,524 | 1× 289 / 12,668；10× 2,880 / 126,520 | PASS：差异很小 |
| 无客户端或共享组件瓶颈 | 未完全证明 | 未完全证明 | QUALIFIED：连接 QPS 有差异，全扫描并发单轮存在噪声 |
| 下载/解码与存储计时已隔离 | 否 | 否 | `NOT ISOLATED`；仅报告端到端观测值 |
| 两侧 AZ 放置一致 | 否：`us-east-1a` × 2 | 否：`us-east-1a` + `us-east-1b` | FAIL：复制写入、跨 AZ 延迟和 HA 不可比 |
| merge 起点 parts 一致 | 2,883 / 2,883 | 2,887 / 2,887 | PASS：差异 0.14%，起点等价 |
| merge 后双副本收敛到 1 part | 否：1 / 13 | 是：1 / 1 | QUALIFIED：本地 span 偏向发起副本，同口径差距应略大于 48.0%（第 9 节第 15 条） |
| merge 计时基准双侧同源 | `part_log` 3,321s（runner 墙钟另为 3,346s） | `part_log` 4,916s（无 runner 墙钟） | PASS：统一采用 `part_log` 口径；跨基准比较已排除（第 9 节第 14 条） |

### 10.2 性能结果

| 阶段 / 指标 | 本地 NVMe | EBS gp3 | 差异 | 判断 |
|---|---:|---:|---:|---|
| 1× warm 43 queries 总耗时 | 19.357s | 19.900s | +2.81% | 同档；工作集可进入内存 |
| 1× direct I/O 43 queries 总耗时 | 22.826s | 40.699s | +78.30% | EBS 在强制绕过 page cache 时明显更慢 |
| 1× direct I/O p95 | 1.759s | 2.646s | +50.43% | NVMe 尾延迟更低；需重复验证 |
| 10× warm 43 queries 总耗时 | 263.391s | 273.694s | +3.91% | 同档到轻微劣化 |
| 10× direct I/O 43 queries 总耗时 | 282.840s | 470.944s | +66.51% | 存储敏感场景 NVMe 优势明确 |
| 10× direct I/O p95 | 32.437s | 39.905s | +23.02% | EBS 尾延迟更高 |
| 10× 端到端摄入 rows/s（含公网下载/解码） | 3,366,919 | 3,662,912 | EBS +8.79% | `NOT ISOLATED`，不能归因于存储 |
| 10× 存储隔离写入 MiB/s | `PENDING` | `PENDING` | `PENDING` | P3b 未完成 |
| 10× 全扫描 QPS（c1 / c8） | 1.862 / 4.250 | 1.803 / 4.169 | -3.17% / -1.91% | c1/c8 基本同档；c2/c4 非单调，单轮不足以定论 |
| merge span（part_log 首尾成功 merge） | 3,321s | 4,916s | EBS +48.0% | 同口径主结论；两侧均由 `part_log` 推导，见第 10.4 节 |
| merge 累计耗时（part_log 求和） | 15,898s | 21,294s | EBS +33.9% | 独立第二度量，不受 span 内空隙影响 |
| 成功 merge 次数 / 输出量 | 512 / 539.42 GiB | 505 / 526.24 GiB | -1.4% / -2.4% | 工作量等价，支撑上面两个时间差可比 |
| merge 期间查询 p99（首 300s 窗口） | 2.279s | 2.237s | -1.84% | 仅覆盖 merge 前段，不预测完成时间，见第 10.4 节 |
| 稳态 SLA 达标率 | `PENDING` | `PENDING` | `PENDING` | `PENDING` |

### 10.3 存储结果

| 指标 | 本地 NVMe | EBS gp3 | 判断 |
|---|---:|---:|---|
| 一分钟平均 / 峰值读写吞吐 | 本轮缺少完整 NVMe 设备序列 | 每卷 106.20 / 1,040.68 与 129.11 / 954.34 MiB/s；双卷窗口平均 235.32、聚合峰值 1,374.76 | 单卷峰值为**卷**预置上限 1,250 MiB/s 的 83.3% / 76.3%，为**实例**通道最大值 1,192.09 MiB/s 的 87.3% / 80.1%；已达实例可持续基线 596.05 MiB/s 的 1.75 / 1.60 倍，只能靠 30 分钟突发额度维持。双卷聚合值仅供参考，两卷分属不同实例，不得与任何单实例限额比较 |
| 一分钟平均 / 峰值 IOPS | 本轮缺少完整 NVMe 设备序列 | 每卷 873.13 / 14,992.98 与 1,030.16 / 9,700.52；双卷窗口平均 1,903.30、聚合峰值 18,754.35 | 40k IOPS 明显留有余量，优先下调 IOPS |
| 平均 / 峰值 queue length | 本轮缺少完整 NVMe 设备序列 | 每卷 1.114 / 11.729 与 1.324 / 9.161；双卷求和 2.438 / 14.802 | 存在阶段性排队，但无持续高队列证据 |
| EBS exceeded / stalled 检查 | 不适用 | 三项指标均返回 0 个 datapoint | 未观察到触发值；缺失 datapoint 不能解释为明确的 0 |

### 10.4 merge 窗口设备级 I/O（首次双侧同口径）

数据来源为 DaemonSet 采集的块设备计数器（约 10s 采样，512 字节扇区，字段定义见 `manifests/80-storage-metrics-collector.yaml`），原始文件 `results/storage-selection-merge-retry/20260812T075959Z/disk-counters-all.tsv`。本地 NVMe 是实例存储，没有对应的 CloudWatch 指标，因此这是本项目**第一份两侧同口径的设备级证据**。取窗按 `part_log`（仅 `error=0`）首尾成功 merge 界定：本地 08:11:36 → 09:06:57（3,321s），EBS 09:07:46 → 10:29:42（4,916s）。

| 指标（每设备，两节点） | 本地 NVMe 实例存储 | EBS gp3 | 判断 |
|---|---:|---:|---|
| 窗口平均读 | 161.0 / 164.6 MiB/s | 106.7 / 108.6 MiB/s | — |
| 窗口平均写 | 163.8 / 166.4 MiB/s | 109.7 / 110.0 MiB/s | — |
| 窗口平均读写合计 | 324.8 / 331.0 MiB/s | 216.4 / 218.6 MiB/s | EBS 平均低约 34%，对应完成时间 +48.0% |
| 每样本 p95 合计 | 1,516.8 / 1,650.6 MiB/s | 1,130.1 / 1,193.4 MiB/s | EBS 上界被预置吞吐夹住 |
| 每样本峰值合计 | 2,629.6 / 2,815.3 MiB/s | 1,263.7 / 1,296.5 MiB/s | 实例存储保有约 2 倍突发余量，EBS 无法达到 |
| 峰值 device utilization | 86.9% / 88.6% | 102.2% / 102.0% | EBS 在 merge 期间已饱和；实例存储未打满 |
| 窗口累计读 + 写 | 1.026 / 1.046 TiB | 1.014 / 1.023 TiB | **等量工作**，两侧搬运字节数基本一致 |
| 平均 IOPS / 每次 I/O 大小 | 2,762 / 2,819；约 120 KiB | 1,415 / 1,428；约 157 KiB | 均低于 SSD merge 的 256 KiB 上限 |

三条判断：

1. **同工不同时。** 两侧窗口累计 I/O 均为每节点约 1.01–1.05 TiB，说明搬运了等量字节；差异只在速率——EBS 平均 217 MiB/s 对本地 328 MiB/s，因此耗时 +48.0%。这与第 10.2 节 direct I/O 的结论方向一致，属于**相互印证**而非冲突。
2. **EBS 已饱和，实例存储仍有余量。** EBS 峰值 utilization 102%、p95 合计约 1,130–1,193 MiB/s，紧贴 1,250 MiB/s 预置上限；实例存储 p95 已达 1,517–1,651、峰值 2,630–2,815 MiB/s，utilization 仍不足 89%。这是**能力余量**差异：EBS 的上界是买来的，实例存储的上界是硬件给的。
3. **吞吐受限而非 IOPS 受限。** 平均吞吐除以平均 IOPS 得每次 I/O 约 120 KiB（本地）和 157 KiB（EBS），均在 256 KiB 合并上限以下。按约 157 KiB 计算，打满 596.05 MiB/s 基线只需约 3,900 IOPS，打满 1,250 MiB/s 也只需约 8,200 IOPS——远低于预置的 40,000。这支持"保吞吐、砍 IOPS"。

EBS 侧窗口平均可与同窗口独立拉取的 CloudWatch 结果交叉校验（读 188.2 + 写 189.9 = 378 MiB/s）。**但两者不是对同一事物的独立证据**：CloudWatch 的取窗为早前的 2,247s 部分窗口，与此处 4,916s 全窗口不同源亦不同长，只能说明量级方向一致，不能作为相互独立的确认。

关于 merge 机制，本报告此前有两处结论需要更正，均已被上表推翻：

- **已废弃说法一（约 81 MiB/s，故 CPU-bound）：** 由最终数据集体积除以墙钟得来（130.245 GiB × 2 副本 / 3,321s ≈ 80.3 MiB/s）。缺陷是忽略了级联写放大——把 2,887 个 parts 收敛为 1 个不是一遍扫描，而是多轮级联，每轮都重读重写工作集。
- **已废弃说法二（约 911 MiB/s，故接近打满 gp3）：** 由 `(2.36 TiB 逻辑读 + 539.42 GiB 压缩写) / 3,321s ≈ 911.5 MiB/s` 得来。该式两处皆错：把未压缩逻辑读与压缩物理写相加，再拿这个和去对比设备带宽。相对设备实测的 324.8–331.0 MiB/s 高估约 2.8 倍。
- **现行结论：** 级联写放大真实存在且值得记录，但必须标注为**逻辑/未压缩**口径——`system.part_log.read_bytes` 报告的是未压缩逻辑字节，不是设备字节。同一批 merge 的 `read_bytes` = 2.36 TiB、`bytes_uncompressed` = 2.00 TiB、`size_in_bytes`（压缩后）= 539.42 GiB，压缩比 3.79 倍。设备口径的权威数字就是上表：本地平均约 328 MiB/s、EBS 平均约 217 MiB/s，EBS 的 p95 被夹在约 1,130–1,193 MiB/s、峰值 utilization 102%（已饱和），而实例存储 p95 达 1,517–1,651、峰值 2,630–2,815 MiB/s。

**并发查询取样边界（重要）：** merge 期间的 4 并发全扫描窗口只有 300s，即本地 merge 的约 9.0%、EBS merge 的约 6.1%，且落在两侧互不对应的阶段。因此它**不是"merge 全程的 QPS"**，两侧也不严格可比。已测得（两侧均 0 失败查询）：

| 指标 | 本地 NVMe | EBS gp3 |
|---|---:|---:|
| 完成查询数 | 775 | 834 |
| QPS | 2.573 | 2.771 |
| p99 | 2.279s | 2.237s |
| 扫描吞吐 | 9,814.473 MiB/s | 10,570.342 MiB/s |

需要读者注意的反直觉之处：**EBS 在头 300s 的 QPS 与尾延迟略优，但整体 merge 晚 48.0% 完成。**短时并发查询采样不能预测 merge 完成时间——规划维护窗口时若只看前几分钟的 QPS，会明显低估 EBS 侧的收敛时长。

### 10.5 HA 与恢复 TODO

> **状态：`TODO`。实际 AZ 拓扑不对称，PDB 尚未归一化，恢复实验尚未完成；以下字段不得由性能结果推断。**

| 指标 | 本地 NVMe | EBS gp3 | 判断 |
|---|---:|---:|---|
| PDB 与故障方法已归一化 | `TODO` | `TODO` | `TODO` |
| Pod 删除到首次成功查询 | `PENDING` | `PENDING` | `PENDING` |
| 节点故障到首次成功查询 | `PENDING` | `PENDING` | `PENDING` |
| 节点故障到完整冗余 | `PENDING` | `PENDING` | `PENDING` |
| 恢复期间错误数 / QPS 降幅 | `PENDING` | `PENDING` | `PENDING` |

### 10.6 成本与最终建议

| 指标 | 本地 NVMe | EBS gp3 | 判断 |
|---|---:|---:|---|
| 两节点计算 + 数据卷/月 | $2,004.29 | $2,380.14 | 当前高配 EBS +18.75% |
| 每十亿行摄入成本 | 不计算 | 不计算 | 公网下载/解码未隔离，结果不具备成本归因条件 |
| 每 TiB 扫描成本 | `PENDING` | `PENDING` | `PENDING` |
| 每百万成功查询成本 | `PENDING` | `PENDING` | `PENDING` |
| 估算运维工时/月 | `PENDING` | `PENDING` | `PENDING` |

**当前建议：默认生产 profile 选择 EBS gp3，保留本地 NVMe 作为明确的性能 profile。**

**适用边界：** warm-cache 与常规并发场景中 EBS 与 NVMe 只有低个位数差异，EBS 更符合固定常驻节点、同 AZ 重挂原卷和降低重灌频率的运维目标。若业务存在频繁绕过 page cache 的大扫描、严格 direct-I/O 尾延迟或持续存储饱和，NVMe 的 23%–78% 本轮优势可能具有决策意义。新增的 merge 证据把这一边界收紧到运维层面：等量工作下 EBS 的 merge 收敛慢 48.0%，因此**维护窗口需按 1.5 倍规划**；若后台 merge 必须在固定夜间窗口内完成，这一项可能比查询延迟更具决策意义。

**需接受的风险：** EBS 方案尚未完成节点故障重挂 RTO、稳态混合负载和多轮重复；本地盘方案仍需接受节点永久丢失后从健康副本或湖仓重灌。当前 AZ 放置不对称，任何复制写入和 HA 结论均无效。此外，`r8g.4xlarge` 为突发型 EBS 通道规格，而本轮 merge 在两侧分别持续 55 与 82 分钟，均远超 30 分钟突发额度；若稳态负载需要长时间高吞吐，应评估 `r8g.8xlarge`（基线等于最大值）而不是依赖突发。

**下一步：** 把 gp3 降到 20k IOPS 并**保持 1,250 MiB/s**——峰值实测约 15k IOPS、且每次 I/O 约 120–157 KiB 表明负载受吞吐而非 IOPS 限制，该档位两节点约 $2,180.14/月、相对本地盘 +8.77%。**不再建议继续下探到 1,000 与 625 MiB/s：** merge 窗口设备数据显示 EBS p95 已达约 1,130–1,193 MiB/s、峰值 utilization 102%，即 merge 期间有超过 5% 的样本运行在 1,100 MiB/s 以上，降到 1,000 MiB/s 会直接削减 merge 吞吐并进一步拉长已经慢 48% 的收敛时间。

> **执行状态：`TODO`，本轮刻意不执行。** 该档位的依据已由本轮实测确定（峰值 IOPS 14,993 / 9,701，merge 窗口仅 1,415 / 1,428；每次 I/O 120–157 KiB，打满 1,250 MiB/s 只需约 8,200 IOPS；`r8g.4xlarge` 的 EBS 持续 baseline 本身就是 20,000 IOPS，预置超出部分只在 30 分钟/24 小时突发额度内可用），无需再补测即可决策。推迟执行的原因是本轮全部实测数据都基于当前 40k IOPS / 1,250 MiB/s 配置，改档会毁掉 merge 与 HA 复现所需的对照基线。建议在 P7/P8 HA 演练完成、集群不再需要保持可复现之后一次性调整。
>
> 执行注意：StorageClass 参数（`terraform/storage.tf`）只作用于新建卷，现有卷须用 `aws ec2 modify-volume` 在线修改（Nitro 上不需卸载或重启），修改后 Terraform state 与实际配置会短暂不一致；每卷每 24 小时最多修改 4 次且需等待上一次进入 `completed`，因此应一次改定。IOPS 与吞吐的比例限制（IOPS ≤ 500 × GiB、吞吐 ≤ 0.25 MiB/s per IOPS）在该档位均不构成约束。

其余待办：双侧收敛到 1/1 的干净 merge 重跑、多轮交替顺序、P3b 存储隔离写入和 P7/P8 HA。

**原始结果目录：** `results/storage-selection/20260812T052520Z`（查询、并发、摄入、CloudWatch）与 `results/storage-selection-merge-retry/20260812T075959Z`（merge 计时与设备级 I/O）
