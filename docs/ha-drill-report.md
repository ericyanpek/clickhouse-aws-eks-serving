# ClickHouse on EKS EBS profile HA 与恢复演练报告

**中文** · [English](./ha-drill-report.en.md)

> 演练日期：2026-08-13
> 主要结论：EBS gp3 profile 在 Pod 删除、优雅驱逐和节点永久丢失三种故障下均保持可用，节点丢失的服务中断为 3 秒、数据零重建；但演练同时暴露一个此前未知的配置缺陷——手写 PDB 与 operator 自动创建的 PDB 重叠，使全部 ClickHouse Pod 永久不可驱逐。该缺陷同样存在于生产 1×3 manifest。
> 适用范围：本报告只覆盖 **EBS gp3 profile**。本地 NVMe profile 的两个副本同处 `us-east-1a`，不具备跨 AZ 故障语义，本轮不做 HA 对比；不得由本报告推断本地 NVMe 的 HA 能力。
> 项目边界：上游数据湖仓保存唯一权威数据事实（SoT）。本报告验证的是加速层的可用性与恢复行为，不改变数据权威边界。

## 1. 为什么单独做 EBS profile

[存储选型报告](./storage-selection-report.md) 的结论是「默认生产 profile 选择 EBS gp3」，理由之一是 EBS 支持同 AZ 重挂原卷、降低节点替换后的重灌频率。在本次演练之前，该理由只是**设计主张，没有实测支撑**——选型报告的 10.5 节把全部 HA 字段标记为 `TODO`，并明确禁止由查询或 merge 性能推断恢复能力。

本轮的目标就是把这一项从主张变成实测：EBS 卷能否在节点永久丢失后重新挂载到替换节点，以及这个过程对服务可用性的实际代价。

## 2. 拓扑与前置条件

| 项目 | 实际值 |
|---|---|
| ClickHouse | `25.3.14.14`，1 shard × 2 replicas |
| 副本 AZ 分布 | `chi-ch-ebs-mainebs-0-0-0` 在 `us-east-1b`，`0-1-0` 在 `us-east-1a` |
| 节点规格 | `r8g.4xlarge`，Pod 14 vCPU / 110 GiB |
| 数据卷 | 每副本一个 gp3，3,400 GiB / 40,000 IOPS / 1,250 MiB/s |
| Keeper | 3 节点，跨 `us-east-1a` / `1b` / `1c` |
| 数据集 | `storage_selection_merge_20260812.hits`，999,974,970 行，130.30 GiB，每副本 1 个 active part |
| 节点组子网 | 每个 EBS 节点组绑定**单一子网**（`us-east-1a` / `us-east-1b` 各一） |

**节点组绑定单一子网是 P8 能够成立的前提。** gp3 卷是 AZ 绑定资源，不能跨 AZ 挂载；因为节点组的子网被固定在卷所在 AZ，替换节点必然落在同一 AZ，卷才可能被重新挂载。若节点组跨多个子网，替换节点可能落到其他 AZ，届时卷无法挂载、Pod 将持续 `Pending`。该约束在演练前已核实。

演练前健康状态：两副本 `is_readonly = 0`、`absolute_delay = 0`、`queue_size = 0`、`active_replicas = 2`。

## 3. 观测方法

演练期间由一个独立 Pod（`workload: bench` 节点，与两个数据副本不同机）以 1 秒间隔持续查询负载均衡后的 `clickhouse-ch-ebs` Service，记录每次尝试的时间戳、耗时、成功与否、以及实际服务的副本名。探针运行在集群内，因此不依赖操作者的 SSM 隧道存活。

查询为 `SELECT hostName() FROM hits LIMIT 1`，`connect_timeout 2` / `receive_timeout 5`。

> **口径边界：** 该探针测量的是**单条轻量查询的服务连续性**，不是吞吐或尾延迟。1 秒采样意味着中断时长的分辨率为 ±1 秒，不能用于论证亚秒级 SLA。探针成功率也不等价于生产可用性——真实客户端有连接池、重试和更重的查询。

## 4. P7：Pod 删除

删除 `chi-ch-ebs-mainebs-0-0-0`，由 operator 的 StatefulSet 自愈。

| 指标 | 实测 |
|---|---:|
| 新 Pod 创建 | t+9s |
| 容器全部 Ready | **t+34s** |
| 探针失败查询 | **0** |
| 服务中断 | **0s** |
| 恢复后复制延迟 | 0s |

窗口内探针 59 次全部成功，流量在 Pod 不可用期间由存活副本承接（`0-1-0` 服务 43 次、`0-0-0` 服务 16 次），延迟 p50 44 ms、最大 57 ms。

> 一处测量陷阱值得记录：删除后立即轮询 Pod 状态会读到**正在终止的旧 Pod** 仍为 `Running:true`，从而得出错误的「2 秒恢复」。必须以新 Pod 的 `creationTimestamp` 为起点判断，本报告的 34s 是按此校正后的值。

## 5. P7b：优雅驱逐（`kubectl drain`）

对承载 `0-1-0` 的节点 `ip-10-0-1-109` 执行 `kubectl drain`。

**第一次尝试失败：**

```
error when evicting pods/"chi-ch-ebs-mainebs-0-1-0" -n "clickhouse":
This pod has more than one PodDisruptionBudget,
which the eviction subresource does not support.
```

根因见第 7 节。移除冗余 PDB 后重试：

| 指标 | 实测 |
|---|---:|
| 两个 PDB 并存时 drain | **失败**（eviction API 拒绝） |
| 移除冗余 PDB 后 drain 完成 | **7s** |
| 探针失败查询 | **0** |
| uncordon 后 Pod 重新就绪 | 20s |

drain 完成后节点处于 cordoned 状态，Pod 保持 `Pending` 属预期行为（无其他可调度节点满足亲和性）；`kubectl uncordon` 后 20 秒恢复 Ready。

## 6. P8：节点永久丢失

停止承载 `0-1-0` 的 EC2 实例 `i-0147e51440dba27ae`（`us-east-1a`），该实例挂载数据卷 `vol-0c5267f45a1e429f4`（3,400 GiB / 40,000 IOPS / 1,250 MiB/s）。这是不可自动回滚的破坏性操作，执行前已获得明确授权。

| 阶段 | 实测 | 说明 |
|---|---:|---|
| 节点转为 `NotReady` | t+10s | 实例进入 `stopping` |
| EBS 卷 detach 为 `available` | **t+86s** | 卷与实例解绑 |
| 替换节点加入集群 | t+86s | `ip-10-0-1-141`，实例 `i-0e8d7d354c0c5754b` |
| 卷重新 attach、Pod `Running` | **t+111s** | 挂载至 `/dev/xvdaa` |
| 服务中断 | **3s**（t+5s 至 t+7s） | 探针 260 次采样中失败 2 次 |
| 探针可用性 | **99.2%** | 260 次 1 秒采样 |
| 恢复后复制延迟 | 0s | |

**替换节点落在 `us-east-1a`**，与原节点及卷同 AZ，符合第 2 节的子网约束预期。

**数据零重建。** 恢复后两副本均为 999,974,970 行、139,911,668,216 字节、1 个 active part，与演练前**逐字节一致**。数据来自重新挂载的原卷，而非从健康副本重新复制。

这是 EBS profile 相对本地 NVMe 的核心差异所在：本地 NVMe 节点永久丢失时，实例存储随之消失，必须触发 [`recover-local-replica.sh`](../scripts/recover-local-replica.sh) 从健康副本或湖仓重灌约 130 GiB；EBS 侧只需等待卷重挂，本轮为 111 秒。

> **本轮未覆盖：** 实例停止是**受控**故障，AWS 有序 detach 了卷。硬件级突发故障、AZ 级故障、以及卷本身损坏均未测试。111 秒也不包含任何数据重灌时间，因为不需要重灌；若卷同时损坏，恢复路径与本地 NVMe 相同，RTO 将由数据量决定而非由重挂决定。

## 7. 演练发现的配置缺陷（比 RTO 数字更重要）

### 7.1 现象

演练前 PDB 状态：

```
NAME                     MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS
ch-ebs-pdb               2               N/A               0
ch-local-pdb             1               N/A               1
chi-ch-ebs-mainebs       N/A             1                 1
chi-ch-local-mainlocal   N/A             1                 1
```

### 7.2 两个独立缺陷

**缺陷一：PDB 重叠导致 Pod 永久不可驱逐。** Altinity operator 会为每个 cluster 自动创建 PDB（`chi-<chi>-<cluster>`，`maxUnavailable: 1`）。仓库中手写的 PDB 以 `clickhouse.altinity.com/chi` 选中**同一批 Pod**，形成重叠。Kubernetes 的 eviction subresource **拒绝任何被超过一个 PDB 覆盖的 Pod**，因此全部 ClickHouse Pod 永久不可驱逐。

**缺陷二：2 副本上 `minAvailable: 2`。** `ch-ebs-pdb` 要求 2 个副本中至少 2 个可用，`ALLOWED DISRUPTIONS` 因此为 `0`，即使不存在重叠也会阻塞驱逐。

### 7.3 影响面

两个缺陷的后果都不限于演练：

- `kubectl drain` 无限期失败
- 节点滚动升级、AMI 轮换无法进行
- Cluster Autoscaler / Karpenter 缩容被阻塞
- Kubernetes 版本升级期间的节点替换被阻塞

即把「高可用」配置成了「不可运维」。

**该缺陷同样存在于生产 1×3 manifest** [`20-clickhouse-chi.yaml`](../manifests/templates/20-clickhouse-chi.yaml.tmpl)。1×3 拓扑在算术上能够承受 `minAvailable: 2`，因此缺陷二不适用；但**缺陷一与副本数无关**，重叠 PDB 在 1×3 上同样使 Pod 永久不可驱逐。

### 7.4 修复

删除全部手写 PDB，仅保留 operator 自动创建的。**保障未减弱**：operator 的 `maxUnavailable: 1` 同样只允许一个副本同时下线，与手写 PDB 的意图一致。

实测验证：两个 PDB 并存时 drain 失败；删除冗余 PDB 后 drain 7 秒完成，零失败查询。

## 8. 结论与边界

**可以主张的：**

1. EBS gp3 profile 在 Pod 删除与优雅驱逐下**零服务中断**。
2. 受控节点永久丢失的服务中断为 **3 秒**，Pod 恢复 `Running` 为 **111 秒**，**数据零重建**——原卷重新挂载至同 AZ 替换节点。
3. 三种故障后复制延迟均归零，数据逐字节一致。
4. EBS 简化同 AZ 节点替换这一设计主张，**至此有了实测支撑**。

**不能主张的：**

1. **不能推断本地 NVMe profile 的 HA 能力。** 其两副本同处 `us-east-1a`，本轮未对其做故障注入。两个 profile 的 HA 对比仍是 `TODO`。
2. **不能作为 SLA 承诺。** 全部为单次演练，无重复轮次、无置信区间。1 秒采样分辨率不支持亚秒级结论。
3. **未覆盖的故障模式：** AZ 级故障、硬件突发故障、卷损坏、Keeper quorum 丢失、网络分区、控制面故障。
4. **不能推断带负载时的 RTO。** 演练期间只有轻量探针负载；在持续写入或 merge 进行中执行同样的故障注入，恢复时间可能显著变长。

**后续 TODO：**

- 本地 NVMe profile 取得对称跨 AZ 拓扑后，重复本演练形成 Apple-to-Apple HA 对比
- 在持续写入负载下重复 P8，测量带负载 RTO
- Keeper quorum 丢失与 AZ 级故障演练
- 多轮重复以形成 RTO 分布而非单点值

**原始结果目录：** `results/ha-ebs/20260813T033253Z`（三段探针日志、前后副本与 parts 状态、卷附着状态、节点与 Pod 快照）。语言无关摘要见 [`perf-results/ha-ebs-20260813-summary.csv`](./perf-results/ha-ebs-20260813-summary.csv)。
