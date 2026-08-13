# 多集群 ClickHouse on EKS IaC 设计

**中文** · [English](./2026-08-13-multi-cluster-clickhouse-iac-design.en.md)

> 状态：设计已确认，待实现。
> 目标：在一套 EKS 控制面下，按需拉起一个或多个相互独立的 ClickHouse 集群，每个集群的拓扑、存储、实例规格和版本均可独立自定义。
> 项目边界不变：上游数据湖仓保存唯一权威数据事实（SoT），ClickHouse 是可重建的 OLAP 加速层。

## 1. 问题陈述

当前 IaC 只能拉起**一个**固定 1 shard × 3 replicas 的集群：

- [`manifests/20-clickhouse-chi.yaml`](../../../manifests/20-clickhouse-chi.yaml) 是静态 YAML，`shardsCount: 1` 与 `replicasCount: 3` 写死，名称与 namespace 也是固定值。
- 节点池由上游 Altinity 模块管理，而该模块以**列表序号**为节点组的 key。
- IRSA、备份、StorageClass 均假定单一集群、单一 namespace。

其中节点组的 key 机制是最硬的约束。上游 `eks/main.tf:89`：

```hcl
eks_managed_node_groups = { for idx, np in local.node_pool_combinations : "node-group-${tostring(idx)}" => {
```

**key 是列表位置的序号。** 因此列表长度或顺序一变，后续所有节点组的地址都会位移，Terraform 会判定需要重建——包括正在服务的节点组。本轮已实际踩到：关闭一个开关导致列表头部少一项，`plan` 中出现活跃节点组重建；至今 `node-group-10` 仍留有孤儿 launch template。

这与目标直接冲突：**新增或删除一个集群，绝不能影响其他集群。**

## 2. 目标与非目标

### 2.1 目标

| 维度 | 要求 |
|---|---|
| 同时 | 一套 EKS 下可存在多个 ClickHouse 集群；默认只起 `ebs` 一个，其余按需追加 |
| 稳健 | 集群间独立、互不影响；启动过程可信赖、不在中途报错；运行期稳定 |
| 可扩展 | 可先起一个，之后随时追加第二个；追加与删除均不触碰既有集群 |
| 可自定义 | 每集群独立指定：拓扑（shards × replicas）、存储介质与容量、实例规格与资源配额、ClickHouse 版本与配置 |

「稳健」的**量化验收标准**：追加或删除一个集群时，`terraform plan` 在既有集群的资源地址上必须显示**零变更**。不接受「看起来没问题」。

### 2.2 非目标

- 不做跨 AZ 或多区域的多 EKS 编排；本设计的范围是一套 EKS 内部。
- 不引入 Karpenter。它虽更贴近弹性目标，但会引入新组件、与 local-NVMe 方案需重新设计，与「启动过程可信赖」相悖。
- 不改变湖仓为唯一 SoT 的架构前提。
- 不实现集群间的数据迁移或联邦查询。

## 3. 架构

### 3.1 集群标识与派生

引入 `clickhouse_clusters` map，**map 的 key 是一切资源的稳定标识符**：

```hcl
clickhouse_clusters = {
  ebs = {
    storage_profile = "ebs"
    shards          = 1
    replicas        = 3
  }
  # 追加第二个集群时解开注释即可，不影响 ebs：
  # nvme = {
  #   storage_profile = "local-nvme"
  #   shards          = 1
  #   replicas        = 2
  # }
}
```

每个 key 派生出一整套互不重叠的资源：

| 资源 | 命名派生 | 隔离级别 |
|---|---|---|
| Kubernetes namespace | `ck-<key>` | 完全隔离 |
| CHI | `<key>`，内部 cluster 名 `main` | 独立 |
| Keeper（CHK） | `keeper-<key>`，3 节点 | **每集群独立一套** |
| 数据节点组 | `for_each` key = `<key>-<az>` | **map-keyed，增删互不影响** |
| Keeper 节点组 | `for_each` key = `<key>-kp-<az>` | 同上 |
| StorageClass | `ck-<key>-gp3` 或 `ck-<key>-local` | 每集群独立档位 |
| Keeper ZooKeeper path | `/clickhouse/<key>/...` | 逻辑隔离 |
| IRSA role | `<cluster_name>-ck-<key>-backup` | 权限隔离 |
| S3 备份前缀 | `s3://<bucket>/<key>/` | 数据隔离 |

Keeper 采用**每集群独立一套**，而非共享。共享方案可省每集群约 $178.70/月，但 quorum 会成为跨集群的共同故障域——Keeper 失去 quorum 会让所有集群同时失去复制能力，与「集群间独立」冲突。

### 3.2 节点组接管（核心机制）

保留上游模块负责 VPC / EKS / addons / autoscaler 与**共享节点池**（`system`、`bench`）——这些数量固定，不会位移。ClickHouse 与 Keeper 的节点组改为自管：

```hcl
locals {
  # 每个 (集群, AZ) 一个节点组，key 为字符串而非序号
  ck_node_groups = merge([
    for name, c in var.clickhouse_clusters : {
      for az in c.zones : "${name}-${az}" => { cluster = name, az = az, ... }
    }
  ]...)
}

resource "aws_eks_node_group" "ck" {
  for_each = local.ck_node_groups
  ...
}
```

**为什么这样就「丝滑」：** `for_each` 的 key 是字符串。删除 `nvme` 这个 key，Terraform 只销毁 `nvme-*` 相关资源，`ebs-*` 的地址完全不变，不产生任何位移。

**单 AZ 单子网是刻意设计。** gp3 卷是 AZ 绑定资源，节点组绑定单一子网才能保证替换节点落在与卷相同的 AZ，从而重新挂载原卷。这一机制已由 [2026-08-13 HA 演练](../../ha-drill-report.md) 验证：节点永久丢失后原卷 111 秒重挂、数据零重建。

### 3.3 外部依赖的获取方式

上游模块仅暴露 5 个 output，不含 node IAM role 与子网。三项依赖均可在不修改上游的前提下获取，且已核实：

| 依赖 | 获取方式 | 核实结果 |
|---|---|---|
| Node IAM role | `data.aws_iam_role`，name = `${cluster_name}-eks-node-role` | 上游 `iam.tf:45` 确认命名规则；本仓库 [`ssm.tf`](../../../terraform/ssm.tf) 已在用同一模式 |
| 每 AZ 私有子网 | `data.aws_subnets`，filter tag Name = `${cluster_name}-vpc-private-${az}` | 已对照实际子网标签确认规则 |
| Cluster 名 / CA / endpoint | 上游 output 与 `data.aws_eks_cluster` | 已暴露 |

### 3.4 必须照抄的节点组属性

上游 `eks/main.tf:89-115` 给出了完整属性清单。自管后以下各项必须显式声明，缺失会导致具体故障：

| 属性 | 缺失后果 |
|---|---|
| `iam_role_arn` + `create_iam_role = false` | 节点无法加入集群 |
| tag `k8s.io/cluster-autoscaler/enabled = "true"` | autoscaler 不识别该节点组 |
| tag `k8s.io/cluster-autoscaler/<cluster_name> = "owned"` | 同上 |
| taint `dedicated=clickhouse:NoSchedule` | 上游对 name 以 `clickhouse` 开头的池自动添加；自管后必须显式声明，否则其他负载会混跑到数据节点 |
| `labels`：`workload`、`storage`、`ck-cluster = <key>` | CHI 的 nodeSelector 无法精确锚定到本集群的节点池 |
| `ami_type`、`disk_size`、`instance_types`、`subnet_ids` | 节点规格或放置错误 |

实现时须逐项对照上游源码核验。

### 3.5 CHI 与 CHK 改为模板渲染

CHI 从静态 YAML 改为由 `deploy.sh` 渲染的模板，以下字段来自 map 中每个集群的配置：`shardsCount`、`replicasCount`、容器 CPU/内存 request 与 limit、`storageClassName`、卷容量、镜像版本、nodeSelector（含 `ck-cluster`）、Keeper 引用与 ZooKeeper path 前缀。

当前 CHI 的资源值是按 `i8g.4xlarge` 手工定尺的，参数化后须与实例规格联动，避免规格与配额不匹配。

## 4. 部署与生命周期

### 4.1 部署流程

```
1. terraform apply 阶段一 → VPC / EKS / addons / 共享池（与集群数量无关）
2. terraform apply 阶段二 → 每集群的节点组、StorageClass、IRSA
3. 对 map 中每个集群依次执行：
     3a. 前置校验
     3b. 渲染 CHK 与 CHI 模板
     3c. 按序 apply：namespace → backup → CHK → 等待 Keeper Ready → CHI
     3d. 等待就绪并执行 smoke test
```

两阶段 apply 沿用现有理由：kubernetes/helm provider 需要一个可达的集群 API，而集群在第一次 apply 完成前并不存在。

### 4.2 前置校验（实现「启动可信赖」）

每个集群在 apply CHI **之前**校验以下各项，任一不满足即失败退出并给出可操作的信息：

| 校验项 | 不校验的后果 |
|---|---|
| StorageClass 存在 | PVC 永久 Pending，且无明显报错 |
| `volumeBindingMode = WaitForFirstConsumer` | AZ 绑定卷可能绑定到错误的 AZ |
| 节点组 Ready 且数量等于 shards × replicas | Pod Pending，原因隐晦 |
| `local-nvme` 时 NVMe 已格式化挂载 | PVC Pending |
| `ebs` 时 EBS CSI DaemonSet 就位 | 卷无法动态供给 |
| 无残留 `REPLACE_WITH` 占位符 | 认证或备份静默失效 |
| Keeper quorum 已就绪 | CHI 反复重启 |

这些校验对应的均是本轮实际遇到过的故障模式。

### 4.3 单集群粒度的销毁

- `teardown.sh --cluster <key>`：只销毁该集群的 CHI、CHK、namespace、节点组与 StorageClass，其他集群不受影响。
- `teardown.sh`：销毁全部；S3 备份桶沿用现有逻辑保留并移出 Terraform state。

因为节点组是 map-keyed，单集群销毁不会改变其他集群的 Terraform 地址。

现有 [`teardown.sh`](../../../scripts/teardown.sh) 中对 storage 资源的 `-target` 已改为从 `terraform state list` 动态获取，以适应 count-gated 的资源地址。

### 4.4 迁移路径

现有集群带有实验遗留：`node-group-10` 孤儿 launch template、storage class 配置漂移、两套并行对比 CHI。且现有节点组的 state 地址（`module.eks.module.eks.module.eks_managed_node_group["node-group-N"]`）与新地址（`aws_eks_node_group.ck["ebs-us-east-1a"]`）无法平滑对应。

因此采用**先销毁、再按新 IaC 重建**。已测得的实验结论（存储选型、HA 演练）已全部归档于 `docs/` 与 `results/`，销毁不丢失结论；重新测量需要重新灌入数据。

## 5. 验证计划

「能真正拉起集群」是本设计的验收前提，因此验证以实际部署为准，而非仅静态检查。

| 步骤 | 内容 | 通过标准 |
|---|---|---|
| 1 | `terraform validate` 与 `plan` 审查 | 资源地址与 tag 符合设计 |
| 2 | 销毁现有集群，从零 apply 默认配置（仅 `ebs`） | smoke test 通过 |
| 3 | 追加 `nvme` 集群 | `plan` 在 `ebs-*` 地址上**零变更**；apply 后两集群同时健康 |
| 4 | 删除 `nvme` 集群 | `plan` 在 `ebs-*` 地址上**零变更** |
| 5 | 检查 autoscaler 识别与 taint 生效 | 节点组被 autoscaler 识别；其他负载无法调度到数据节点 |

第 3 与第 4 步是「独立丝滑」的量化验收标准。

**成本提示：** 第 3 步会短时间内同时运行两个集群。按 1 shard × 3 replicas、`r8g.4xlarge` 与 20k IOPS / 1250 MiB/s gp3 估算，单集群约 $3,449/月的费率（数据节点约 $2,064、Keeper 约 $179、卷约 $1,206），另有约 $196/月的共享成本。验证期间可让第二个集群使用更小的实例与卷，因为它只用于验证「追加不影响既有集群」，无需承载性能测试。

## 6. 风险与缓解

| 风险 | 缓解 |
|---|---|
| 遗漏上游节点组属性，导致 autoscaler 不识别或 taint 缺失 | 实现时逐项对照上游 `eks/main.tf:89-115`；验证第 5 步专门检查 |
| 上游模块升级后命名规则变化（node role、子网 tag） | 依赖点集中在 3.3 的三个 data source，升级时集中核验；模块版本已钉在 `v0.5.7` |
| 多集群下共享 autoscaler 的行为未验证 | 验证第 5 步覆盖；必要时按集群拆分 autoscaler 优先级 |
| 每集群独立 Keeper 使成本上升 | 明确为设计取舍；默认只起一个集群，其余按需 |
| CHI 模板参数化引入渲染错误 | 前置校验含占位符残留检查；smoke test 验证实际拓扑与期望一致 |

## 7. 待后续处理

以下不属于本设计范围，但需记录：

- 本地 NVMe profile 的 HA 演练（需对称跨 AZ 拓扑）。
- 带写入负载的 P8 节点故障演练。
- gp3 档位下调后的性能中性验证——降档后未实测，不得与降档前数字直接相减。
