# ClickHouse 本地 NVMe 与 EBS 性能对比结果

**中文** · [English](./storage-comparison-results.en.md)

> 测试日期：2026-08-11  
> 结论：在 13.48 GiB、可完整进入 110 GiB 内存的 ClickBench 数据集上，`r8g.4xlarge + gp3` 的 43 条 warm 查询与历史 `i8g.4xlarge + local NVMe` 基本同档；该结果不能证明 EBS 与 NVMe 在冷数据或持续 merge 下等价。

## 1. 对比合同

本轮只重新测试 EBS，NVMe 使用 2026-07-05 的历史实测。EBS 侧锁定：

| 项目 | NVMe 历史基线 | EBS 本轮 |
|---|---|---|
| ClickHouse | 25.3.14.14 | 25.3.14.14 |
| 拓扑 | 1 shard × 2 replicas | 1 shard × 2 replicas |
| 数据节点 | 2 × i8g.4xlarge | 2 × r8g.4xlarge |
| Pod 资源 | 14 vCPU / 110 GiB | 14 vCPU / 110 GiB |
| 压测端 | 独立 c7g.2xlarge | 独立 c7g.2xlarge |
| 数据 | 99,997,497 行 | 99,997,497 行 |
| 表 | 105 列 `ReplicatedMergeTree` | 相同 105 列、分区键、排序键和采样键 |
| 查询 | ClickBench 43 queries | 同一历史文件，SHA-256 `a7d6673357348ee9680443216b6f26f30d1dce9f313b419d38502417b2c2a219` |

EBS 每副本为 3400 GiB gp3，预置 40,000 IOPS / 1,250 MiB/s。所有性能流量从 EKS 内的 benchmark Pod 访问 ClusterIP；本地 Mac 只通过 SSM/Kubernetes API 编排测试。

### 1.1 取证边界

历史 NVMe 报告保留了 ClickHouse 版本、表键片段、43 条结果和 QPS 日志，但没有保存完整运行时 `SHOW CREATE TABLE` 或 active-parts 清单，旧 Keeper 表路径也已不存在。本轮从 2026-07-05 当时的 ClickBench 提交恢复了 43 条 SQL，并把官方 DDL 在 ClickHouse 25.3 下的 105 列类型和项目键定义固化到脚本。

因此，本轮实现了可重复的逻辑合同；但无法对已销毁 NVMe 表的全部 105 列做事后哈希证明。过滤聚合还暴露了物理 parts 布局差异，见第 3 节。

## 2. 43 条 warm 查询

每条查询单连接运行 3 次取最优：

| 指标 | NVMe | EBS | EBS 相对 NVMe |
|---|---:|---:|---:|
| 总耗时 | 18.756s | 18.334s | -2.25% |
| 平均 | 0.436s | 0.426s | -2.29% |
| p50 | 0.175s | 0.172s | -1.71% |
| p90 | 1.268s | 1.250s | -1.42% |
| 最慢 Q29 | 5.211s | 5.081s | -2.49% |

`-2.25%` 不应解释为 EBS 比 NVMe 更快。数据小于内存，warm best-of-3 主要测量 Graviton4 CPU、ClickHouse 执行和 page cache；这个差异属于同档波动。

原始结果：

- NVMe：[`perf-results/clickbench-43queries.csv`](./perf-results/clickbench-43queries.csv)
- EBS warm + direct I/O：[`perf-results/ebs-gp3-clickbench-43queries.csv`](./perf-results/ebs-gp3-clickbench-43queries.csv)

## 3. QPS

三类查询使用并发 8、12 秒；全表聚合另跑并发 1/2/4/8/16：

| 查询类型 | NVMe QPS | EBS QPS | 判断 |
|---|---:|---:|---|
| 点查 `WHERE CounterID=62` | 2774.391 | 2416.823 | EBS -12.9%，可比 |
| 过滤聚合 | 369.720 | 1032.252 | **不可比** |
| `SELECT 1` | 5851.224 | 5268.330 | EBS -10.0%，主要是请求链路/CPU |
| 全表 `GROUP BY RegionID` | 47.900 | 50.651 | EBS +5.7%，同档 |

过滤聚合两边运行的是同一条 SQL：

```sql
SELECT RegionID, count()
FROM hits
WHERE CounterID = 62
GROUP BY RegionID
ORDER BY count() DESC
LIMIT 10;
```

但 NVMe 日志显示每查询读取约 8,530,531 行，EBS 只读取 743,073 行。测试时 EBS 每副本已经合并为 2 个 active parts；历史 NVMe 没有 parts 清单。主键 mark 过读量差 11.5 倍，所以 `369.720` 与 `1032.252` 不是存储介质对比，不能用于选型。

全表扫描每次都读取 99,997,497 行，不受该差异影响：

| 并发 | NVMe QPS | EBS QPS |
|---:|---:|---:|
| 1 | ~22.5 | 22.195 |
| 2 | ~44.8 | 44.258 |
| 4 | ~50.5 | 45.673 |
| 8 | ~52.0 | 50.651 |
| 16 | ~52.0 | 48.199 |

汇总数据见 [`perf-results/ebs-gp3-qps-summary.csv`](./perf-results/ebs-gp3-qps-summary.csv)。

## 4. EBS direct I/O

`min_bytes_to_use_direct_io=1` 是 EBS-only 诊断，历史 NVMe 没有同口径结果，不能做横向比值：

| 指标 | EBS warm | EBS direct I/O |
|---|---:|---:|
| 43 查询总耗时 | 18.334s | 39.568s |
| 平均 | 0.426s | 0.920s |
| p50 | 0.172s | 0.427s |
| p90 | 1.250s | 2.202s |
| Q24 | 1.307s | 6.755s |
| Q29 | 5.081s | 6.116s |

这证明绕开 page cache 后存储路径会显著影响部分查询，但不能证明同条件 NVMe 会快多少。

## 5. EBS 观测

测试窗口的 CloudWatch 1 分钟指标：

| 指标 | us-east-1b 卷 | us-east-1a 卷 |
|---|---:|---:|
| 峰值读取吞吐 | ~332 MiB/s | ~224 MiB/s |
| 峰值读取 IOPS | ~3,880 | ~2,270 |
| VolumeQueueLength 平均值峰值 | 3.24 | 1.92 |
| 实例 EBSByteBalance% 最低 | 99% | 99% |
| 实例 EBSIOBalance% 最低 | 99% | 99% |

本轮远未达到单卷 40,000 IOPS / 1,250 MiB/s 的预置值。对这个 13.48 GiB 读测试，20,000 IOPS / 625 MiB/s 很可能已经足够；是否下调必须再用目标写入、merge 和恢复负载验证。

## 6. HA 测试状态与 TODO

本轮**没有执行 EBS HA 测试**，因此不能用这份报告证明服务连续性、EBS 重挂时间或恢复 RTO。下次测试必须先恢复 Operator、Keeper、1 shard × 2 replicas 的 EBS CHI，并重新装载同一份 99,997,497 行数据。

第一项必须是与历史 NVMe 完全同口径的 **Pod 删除测试**，不能用节点终止测试替代：

- 从独立 `c7g.2xlarge` benchmark 节点访问 ClusterIP。
- 固定查询为 `SELECT RegionID, count() FROM hits GROUP BY RegionID ORDER BY count() DESC LIMIT 10`。
- `clickhouse-benchmark` 使用并发 4 和 `--continue_on_errors`，持续运行期间删除一个 ClickHouse 副本 Pod。
- 记录双副本基线 QPS、单副本 QPS、查询错误数、服务是否持续可用、Pod 删除到 Ready、Pod 删除到首次查询成功、复制队列清空时间。
- 删除前后记录 Pod 节点、PVC、PV 和 `VolumeAttachment`，确认替代 Pod 是否复用同一 EBS 卷。

历史 NVMe 对照为：双副本约 47–48 QPS、单副本约 25–26 QPS、1 个瞬时错误、约 65 秒恢复。该结果同样是节点保留的 Pod 删除测试。**节点丢失后的 EBS detach/attach 是第二个独立场景**，应另测同 AZ 调度、卷重挂和 ClickHouse 恢复时间。

2026-08-11 收尾状态：EKS 和 9 台 EC2 节点保持运行，未执行 EC2 stop/terminate 或 Terraform 基础设施销毁；但 ClickHouse namespace、Keeper、EBS CHI、PVC 和测试数据已在中止的清理过程中移除，Operator 重装也因 SSM/Kubernetes API 超时而未完成。下次测试应从 Operator 和工作负载恢复开始，不能假设当前集群仍保存 ClickHouse 数据。

## 7. 决策

1. 对能完整进入内存的 ClickBench warm 查询，R8g + 高配 gp3 与 i8g + NVMe 同档；该场景的差异不足以作为存储介质选型依据。
2. EBS 的主要架构价值仍是节点故障后同 AZ 重挂原卷；本轮没有执行节点故障恢复测试，不能给出实测 RTO。
3. direct-I/O 说明存储敏感查询仍可能受 EBS 影响。要证明 NVMe 优势，需要同一时点、相同 parts 布局下扩大数据集，并增加持续 INSERT/merge 测试。
4. 过滤聚合 QPS 不应进入选型表，除非两边先执行相同的 parts 整理策略并记录 `system.parts`。
5. 项目定位不变：湖仓保存唯一权威数据事实，ClickHouse 是可重建的 OLAP 加速层；EBS 与 NVMe 只是性能、成本和恢复模型的不同 profile。
