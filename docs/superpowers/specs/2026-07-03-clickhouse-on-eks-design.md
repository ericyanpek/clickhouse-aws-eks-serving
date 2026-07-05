# ClickHouse on EKS 部署方案设计

> 日期:2026-07-03
> 产出形态:可评审、可执行的 IaC 代码(Claude 编写,用户自行 `terraform apply`)。**本方案不代为对真实 AWS 账号执行 apply。**
> 依据调研:见 [`docs/clickhouse-on-eks-research.md`](../../clickhouse-on-eks-research.md)

---

## 1. 目标与决策汇总

| 维度 | 决策 |
|---|---|
| 产出 | 可评审的 IaC 代码,用户自己 apply |
| 拓扑 | **1 分片 × 3 副本 + 3 Keeper**(3 个 ClickHouse 节点 + 3 Keeper 节点) |
| EKS 来源 | 全新 VPC + EKS,**复用 Altinity Terraform EKS Blueprint 的 `eks/` 子模块(钉 v0.5.7)**;方案 1 混合式 |
| 存储 | **本地 NVMe**(i8g.4xlarge 实例,ARM/Graviton),方案 A:钉住 + 三副本兜底 |
| 网络暴露 | ClusterIP(集群内部访问) |
| 监控 | Prometheus + Grafana(kube-prometheus-stack) |
| 备份 | clickhouse-backup → S3(通过 IRSA 授权) |
| 版本 | 钉定具体版本(operator 0.27.1 + ClickHouse 稳定 LTS) |

---

## 2. 核心架构权衡:本地 NVMe(已确认方案 A)

本地 NVMe 追求极致 IO 性能,但与 K8s "Pod 自由漂移" 理念天然冲突,是本方案风险最高的点。采用 **方案 A**:

- 用 `local-static-provisioner`(或 `local` PV)把每个 ClickHouse Pod 钉死在特定 i8g.4xlarge 节点。
- 反亲和保证:**3 个副本分别落在不同 AZ 的不同节点**。
- 节点故障 → 该副本本地数据丢失 → 靠另外两 AZ 的副本 + Keeper 自动重建。
- **前提条件**:三副本(已选)+ S3 备份(已选)。本地盘无快照,S3 备份是唯一灾难兜底。
- 代价:节点故障后恢复需重新拉全量数据,恢复期该分片降级为两副本(不中断服务)。

**拓扑选型原则(先扩容,后分片)**:当前采用 1 分片 × 3 副本而非多分片,是因为 ClickHouse 分片没有自动 rebalance 机制——增加分片后存量数据不会自动迁移,运维成本高。推荐策略:优先垂直扩容(升大 i8g 实例),直到单节点查询成为瓶颈再引入多分片。

**Keeper 例外**:Keeper 用 **gp3** 而非本地盘。Keeper 数据小、需持久、挂一个节点要能在别处用 PV 重建——本地盘做不到。

---

## 2.5 复用 Altinity EKS Blueprint(方案 1 混合式,已确认)

经审查上游 `Altinity/terraform-aws-eks-clickhouse`(v0.5.7)源码,确定分工:

**复用 blueprint 的部分(成熟、AWS 官方合作,不重造轮子):**
- `//eks` 子模块:VPC + 3 AZ 子网 + NAT + EKS 集群 + 节点组 + cluster-autoscaler + IAM。作为 child module 引用(该子模块不含内部 provider 块,可干净消费)。
- `//clickhouse-operator` 子模块:安装 Altinity operator(版本钉到 `0.27.1`,覆盖其默认 `0.24.4`)。

**丢弃 blueprint 的部分(封闭、表达不了本设计):**
- `//clickhouse-cluster` 子模块——弃用。其 CHI 拓扑写死在上游 helm chart `clickhouse-eks`(0.1.8),TF 仅暴露 zones/instance_type/name/user/password,**无法配置自定义分片/副本拓扑、本地 NVMe(它写死 `gp3-encrypted`)、反亲和、备份**。改为我们自己写 CHI/CHK manifests。

**blueprint 接口约束(计划中必须遵守):**
- `eks_node_pools` 节点名**强制** `clickhouse` 或 `system` 前缀(有 validation)→ Keeper 节点组命名为 `system-keeper`。
- Provider 版本锁:AWS `~> 5.40`、helm `>= 2.9, < 3.0`、kubernetes `>= 2.25.2`。
- OIDC provider ARN 未在根 outputs 暴露 → clickhouse-backup 的 IRSA 由我们在 wrapper 里用 `data.aws_eks_cluster` + `aws_iam_openid_connect_provider` 数据源自建。

## 3. 整体架构

```
┌─────────────────────────────────────────────────────────────┐
│ 全新 VPC (3 AZ: a/b/c)                                        │
│                                                               │
│  ┌──── EKS 集群 ────────────────────────────────────────┐    │
│  │                                                        │    │
│  │  节点组 1: system (gp3, 通用实例 2x)                    │    │
│  │    ├─ Altinity clickhouse-operator (0.27.1)           │    │
│  │    ├─ kube-prometheus-stack (Prometheus + Grafana)    │    │
│  │    └─ aws-ebs-csi-driver / local-static-provisioner   │    │
│  │                                                        │    │
│  │  节点组 2: clickhouse (i8g.4xlarge, ARM/Graviton, 本地 NVMe, 3x 跨 AZ)  │    │
│  │    ├─ shard0-replica0 (AZ-a)                            │    │
│  │    ├─ shard0-replica1 (AZ-b)                            │    │
│  │    └─ shard0-replica2 (AZ-c)                            │    │
│  │                                                        │    │
│  │  节点组 3: keeper (gp3, 小实例 3x 跨 AZ)                │    │
│  │    └─ keeper-0(a) keeper-1(b) keeper-2(c)  [CHK CRD]   │    │
│  └────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
        │ IRSA                          │ backup
        ▼                               ▼
   ClickHouse Service (ClusterIP)   S3 Bucket (clickhouse-backup)
```

**设计原则**:
- 三个独立节点组,职责隔离(系统组件 / ClickHouse / Keeper 互不干扰)。
- Keeper 独立部署(CHK CRD),绝不与 ClickHouse 混布——研究报告的硬性最佳实践。
- 分层解耦:Terraform 管 AWS 基础设施 + Helm addons;manifests 管 ClickHouse 业务拓扑(CHI/CHK)。可改 CHI 拓扑而不动 Terraform。

---

## 4. 代码结构(交付物)

```
clickhouse-deployment/
├── docs/
│   ├── clickhouse-on-eks-research.md        # 已有调研
│   └── superpowers/specs/2026-07-03-...-design.md  # 本设计文档
├── terraform/
│   ├── versions.tf          # provider 版本锁(aws ~>5.40, helm <3, k8s >=2.25)+ backend
│   ├── providers.tf         # aws/kubernetes/helm provider(指向 EKS,exec 取 token)
│   ├── eks.tf               # module "eks" → Altinity blueprint //eks 子模块 (v0.5.7)
│   ├── operator.tf          # module "operator" → blueprint //clickhouse-operator (钉 0.27.1)
│   ├── storage.tf           # gp3 StorageClass + local-static-provisioner (helm)
│   ├── monitoring.tf        # kube-prometheus-stack (helm)
│   ├── irsa.tf              # OIDC 数据源 + clickhouse-backup 的 IAM role/policy
│   ├── s3.tf                # 备份 bucket(加密/阻断公有/版本化)
│   ├── variables.tf         # 所有可调参数(版本、实例类型、副本数…)
│   ├── outputs.tf           # kubeconfig 命令、service 地址、bucket 名
│   └── terraform.tfvars     # 钉定的默认值(apply 前审这个)
├── manifests/
│   ├── 00-namespace.yaml
│   ├── 10-keeper-chk.yaml         # ClickHouseKeeperInstallation, 3 节点
│   ├── 20-clickhouse-chi.yaml     # ClickHouseInstallation, 1x3 + 反亲和 + 本地盘
│   ├── 30-backup-cronjob.yaml     # clickhouse-backup → S3
│   └── 40-grafana-dashboard.yaml  # dashboard #12163 ConfigMap
├── scripts/
│   ├── deploy.sh            # 编排:terraform apply → 装 CRD → apply manifests
│   ├── smoke-test.sh        # 建分布式表、写入、跨副本验证、查 system.replicas
│   └── teardown.sh          # 有序销毁(先删 CHI 再 terraform destroy)
└── README.md               # 前置条件、apply 步骤、验证、成本估算、销毁
```

---

## 5. 关键实现要点

1. **本地盘钉住**:clickhouse 节点组用 i8g.4xlarge(ARM/Graviton,~3.75TB NVMe,数据卷 3400Gi/副本);`local-static-provisioner` 发现 NVMe → local PV;CHI 的 `dataVolumeClaimTemplate` 用 `local-storage` StorageClass(`WaitForFirstConsumer`)。
2. **反亲和 + 跨 AZ**:CHI `podTemplate` 中 `podAntiAffinity`(topologyKey=`kubernetes.io/hostname`,三副本各落不同主机)+ `topologySpreadConstraints`(topology.kubernetes.io/zone 跨 AZ)。
3. **资源模型(专属节点)**:每个 i8g.4xlarge 节点只跑一个 ClickHouse Pod(one-pod-per-dedicated-node)。CPU request 设高值(如 `"14"`)但**不设 CPU limit**——避免 CFS throttle 在突发查询时伤害延迟;memory request == limit(`"110Gi"`)保证 QoS Guaranteed,防止 OOM 驱逐;CHI 配置 `max_server_memory_usage_to_ram_ratio: "0.9"` 为页缓存留出约 10% 余量。
4. **Keeper**:独立 CHK,3 节点跨 AZ,gp3 PVC;CHI 通过 `zookeeper` 配置引用 CHK service。
5. **备份**:clickhouse-backup 作为 CronJob,IRSA 授权访问 S3,每日全量 + 可选增量。
6. **版本钉定**:operator `0.27.1`;ClickHouse 选近期稳定 LTS,在 `terraform.tfvars` 中标注具体版本号 + 注释,apply 前由用户确认。
7. **安全默认**:ClusterIP;S3 bucket 加密 + 阻断公有访问 + 版本化;节点组置于私有子网。

---

## 6. 验证与测试策略

`smoke-test.sh` 做端到端验证(不止 "Pod Running"):
- 建 `ReplicatedMergeTree` + `Distributed` 表
- 向一个副本写入 → 查另一副本确认同步(验证 Keeper 生效)
- `system.replicas` / `system.clusters` 检查拓扑健康
- 杀一个 ClickHouse Pod → 确认另一副本仍可查(验证 HA)

---

## 7. 成本与安全提示(README 明示)

- 3× i8g.4xlarge(ARM/Graviton,单价约 $1.35/hr)+ 3× 小 Keeper + 2× system + NAT + EKS 控制面 → 粗估每天约 $120–160(压测升大实例会更高),README 给按需估算表。
- teardown 脚本保证有序销毁(先删 CHI/CHK 让 operator 清理 → 再 terraform destroy),避免 orphan EBS/NLB 继续计费。

---

## 8. 非目标(YAGNI)

- 不做公网暴露、不配 TLS 终止(ClusterIP 起步,后续按需加 Ingress/NLB)。
- 不做多集群 / 多租户。
- 不做自动扩缩容策略调优(节点组给固定容量,留 autoscaling 开关但不深调)。
- 不代为执行 apply。

---

## 9. 未决 / 需用户 apply 前确认

- `terraform.tfvars` 中 ClickHouse 具体 LTS 版本号(代码里给推荐值 + 注释)。
- AWS region 与 3 个 AZ 的具体名称(变量化,默认给占位需用户填)。
- i8g 实例规格(默认 `i8g.4xlarge`,可在 tfvars 调整;`clickhouse_ami_type` 默认 `AL2023_ARM_64_STANDARD`,切换为 x86 实例时须同步修改)。升大实例(如 `i8g.8xlarge` / `i8g.12xlarge`)做压力测试时,须同步手工调整 CHI 中的 CPU/memory 资源请求及数据卷大小(当前值按 i8g.4xlarge 定制)。
