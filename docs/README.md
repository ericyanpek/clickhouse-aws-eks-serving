# 文档索引

**中文** · [English](./README.en.md)

本页说明仓库内各文档的权威级别、语言和适用范围，防止历史设计或测试环境被误认为当前实现。

## 权威入口

| 文档 | 状态 |
|---|---|
| [`README.md`](../README.md) / [`README.en.md`](../README.en.md) | 当前中英文权威入口，必须同步维护 |

两份根 README 必须保持相同章节编号、命令、版本、拓扑、恢复模型和项目边界。任何用户可见行为变更都必须同时修改两份文件。

## 支持材料

| 中文 | English | 状态与用途 |
|---|---|---|
| [`clickhouse-on-eks-research.md`](./clickhouse-on-eks-research.md) | [`clickhouse-on-eks-research.en.md`](./clickhouse-on-eks-research.en.md) | 截至文档日期的生态调研；版本信息可能过期 |
| [`community-corroboration.md`](./community-corroboration.md) | [`community-corroboration.en.md`](./community-corroboration.en.md) | 外部案例和设计主张证据 |
| [`notes-ck-on-eks-best-practices-2026.md`](./notes-ck-on-eks-best-practices-2026.md) | [`notes-ck-on-eks-best-practices-2026.en.md`](./notes-ck-on-eks-best-practices-2026.en.md) | 架构推演，明确湖仓为唯一 SoT |
| [`perf-testing-plan.md`](./perf-testing-plan.md) | [`perf-testing-plan.en.md`](./perf-testing-plan.en.md) | 当前 1×3 目标的测试计划 |
| [`perf-test-report.md`](./perf-test-report.md) | [`perf-test-report.en.md`](./perf-test-report.en.md) | **历史 1×2 实测结果**，不得当作当前 1×3 实测 |
| [`storage-comparison.md`](./storage-comparison.md) | [`storage-comparison.en.md`](./storage-comparison.en.md) | 可选 R8g + 高性能 gp3 与现有 i8g + local NVMe 的并行 A/B 方案 |
| [`storage-comparison-results.md`](./storage-comparison-results.md) | [`storage-comparison-results.en.md`](./storage-comparison-results.en.md) | **2026-08-11 历史 1×2 EBS-only 实测**，包含 Apple-to-Apple 边界与 CloudWatch 证据 |
| [`storage-selection-report.md`](./storage-selection-report.md) | [`storage-selection-report.en.md`](./storage-selection-report.en.md) | **2026-08-12 同轮本地 NVMe 与 EBS 选型实验**；查询、CloudWatch、merge 计时与 merge 窗口设备级 I/O 结果已记录，EBS profile 的 HA 演练见 HA 报告 |
| [`ha-drill-report.md`](./ha-drill-report.md) | [`ha-drill-report.en.md`](./ha-drill-report.en.md) | **2026-08-13 EBS profile HA 与恢复演练**；Pod 删除、优雅驱逐、节点永久丢失的实测 RTO，并记录 PDB 重叠导致 Pod 不可驱逐的缺陷。不覆盖本地 NVMe profile |
| [`superpowers/specs/2026-07-03-clickhouse-on-eks-design.md`](./superpowers/specs/2026-07-03-clickhouse-on-eks-design.md) | [`superpowers/specs/2026-07-03-clickhouse-on-eks-design.en.md`](./superpowers/specs/2026-07-03-clickhouse-on-eks-design.en.md) | 当前设计背景；实现与根 README 优先 |
| [`superpowers/plans/2026-07-03-clickhouse-on-eks.md`](./superpowers/plans/2026-07-03-clickhouse-on-eks.md) | [`superpowers/plans/2026-07-03-clickhouse-on-eks.en.md`](./superpowers/plans/2026-07-03-clickhouse-on-eks.en.md) | **历史实施记录**，包含已废弃的 2×2/i4i 步骤，不是操作手册 |

`perf-results/clickbench-43queries.csv`、`perf-results/ebs-gp3-clickbench-43queries.csv`、`perf-results/ebs-gp3-qps-summary.csv` 、`perf-results/storage-selection-20260812-summary.csv` 和 `perf-results/ha-ebs-20260813-summary.csv` 只有语言无关的字段名与数值，保留单份。带中文分组标题的 [`perf-results/qps-by-query-type.txt`](./perf-results/qps-by-query-type.txt) 已配套提供 [`英文版`](./perf-results/qps-by-query-type.en.txt)。

## 项目不变量

以下事实必须在所有当前文档中保持一致：

1. 数据湖仓承接唯一权威数据事实（SoT）；ClickHouse 是其下游派生、最终一致、可重建的 OLAP 加速层。
2. 当前目标拓扑是 1 shard × 3 replicas；性能报告的 1×2 数据只能按历史实测引用。
3. ClickHouse 和 Keeper 镜像钉在 25.3 LTS，operator 钉在 0.27.1。
4. 本地 NVMe 节点永久丢失需要人工触发 local-PV 恢复流程，不是全自动恢复。
5. S3 backup bucket 仅是 ClickHouse 恢复点，不是湖仓 SoT；teardown 后保留且不再由 Terraform state 管理。
6. 本仓库不实现湖仓、Kafka/Flink 管道或 ClickHouse Cloud/OSS 双写。

## 同步规则

- 无语言后缀的 Markdown 文件是中文版，`.en.md` 是英文版。
- 每份文档的 H1 下方必须提供中英文双向跳转。
- 两个版本必须保留相同的章节结构、代码块、命令、URL、数字、版本和技术结论。
- 提交文档变更前运行 `./scripts/check-docs.sh`。
