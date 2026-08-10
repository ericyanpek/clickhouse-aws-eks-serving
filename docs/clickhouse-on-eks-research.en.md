# ClickHouse on Amazon EKS Ecosystem and Best Practices Research Report

[中文](./clickhouse-on-eks-research.md) · **English**

> Research date: 2026-07-03
> Methodology: Deep research workflow (5 search angles · 21 sources retrieved · 103 claims extracted · the top 25 claims subjected to adversarial validation with 3 votes each, with 22 confirmed / 3 disproven)
> Evidence reliability note: Much of the evidence comes from first-party vendor sources (official Altinity / ClickHouse materials), which are reliable for factual capability claims; however, wording such as "most mature," "most thoroughly tested," and "cleanest approach" is self-promotional and lacks independent quantification. Version numbers will drift over time.

---

## I. Key Conclusion: The Operator Is the Center of the Entire Ecosystem

**The Altinity Kubernetes Operator for ClickHouse is the de facto standard**, with no second option mature enough to compete with it.

| Attribute | Facts (verified on 2026-07-03) |
|---|---|
| License | Apache 2.0 |
| Stars / Releases | ~2,526 stars, 88 releases, latest **0.27.1 (2026-06-04)** |
| Platform coverage | **Explicitly tested on AWS EKS** (as well as GKE / AKS / Minikube) |
| Endorsement | Has underpinned **Altinity.Cloud since 2019**; users include eBay, Cisco, and Twilio |
| Maturity | ★★★★★ Production-grade; recommended as the default choice |

Sources (primary):
- https://github.com/Altinity/clickhouse-operator
- https://altinity.com/kubernetes-operator
- https://docs.altinity.com/altinitykubernetesoperator

**Authoritative pattern validation**: ClickHouse's official BYOC on AWS itself follows this pattern: it runs a ClickHouse operator plus supporting services (ingress, DNS, certificate management, state exporters, and scrapers) on EKS in the customer's VPC, stores logs/metrics on EBS, and uses the Prometheus/Thanos stack. The management plane resides in ClickHouse's own VPC, accesses the environment through private endpoints, and does not directly access customer data. In effect, ClickHouse has validated the "operator on EKS" approach in production at scale.
- https://clickhouse.com/docs/cloud/reference/byoc/architecture
- https://clickhouse.com/blog/building-clickhouse-byoc-on-aws

> ⚠️ **Important open question**: ClickHouse Inc. launched its official ClickHouse Kubernetes Operator in **2026-01** (distinct from Altinity's). This study did not independently verify its functionality / maturity / EKS support. Dedicated research is required before making a selection: if the official operator is now mature, it may change the default recommendation over the long term.

---

## II. Coordination Layer: ClickHouse Keeper (Not ZooKeeper)

Use **ClickHouse Keeper** for all new deployments; retain ZooKeeper only when migrating existing deployments.

- A single C++ binary with **no JVM / no external dependencies**; its client protocol is compatible with ZooKeeper; consensus uses **NuRAFT (Raft)**, whereas ZK uses ZAB.
- Responsible for replica synchronization and distributed DDL; **some features (such as S3Queue) strictly require Keeper** (ClickHouse GitHub issue #70398).
- **Cluster size: an odd number of nodes, with 3 recommended**. Altinity explicitly **does not recommend more than 3 voting nodes** (excluding observers): larger clusters slow leader election and commits, which in turn increases insert/DDL latency.
- **Deployment method on K8s**: Use the dedicated `ClickHouseKeeperInstallation` (CHK) CRD (`clickhouse-keeper.altinity.com/v1`), with `tcp_port 2181`, Raft server port `9444`, `storage_path /var/lib/clickhouse-keeper`, and `four_letter_word_white_list`. CHK has been production-ready since operator **0.24.0**, and 0.27.x supports CHIs referencing a CHK.

Sources:
- https://kb.altinity.com/altinity-kb-setup-and-maintenance/altinity-kb-zookeeper/clickhouse-keeper
- https://clickhouse.com/docs/guides/sre/keeper/clickhouse-keeper

> ⚠️ **Correction (claim disproven by validation)**: "Every ClickHouse cluster must reference Keeper" is **an overstatement**. Keeper is strongly recommended but not universally mandatory (a single-shard, unreplicated deployment that does not use distributed DDL can operate without it).

---

## III. Monitoring Stack

**Recommended: built-in / operator exporter + Prometheus + Grafana.**

- ClickHouse **includes a Prometheus endpoint** (port `9363`, `/metrics`). Modern versions (~20.3+) have made the older external `clickhouse_exporter` unnecessary (that project is no longer maintained).
- When using the operator, use its **metrics-exporter** (port `8888`, `/metrics`).
- Ready-made Grafana dashboard: the official **Altinity operator dashboard #12163**.

Sources:
- https://kb.altinity.com/altinity-kb-setup-and-maintenance/altinity-kb-monitoring
- https://github.com/ClickHouse/clickhouse_exporter
- https://grafana.com/grafana/dashboards/12163

---

## IV. Production Best Practices: Cross-AZ Placement and Scheduling

**Primary objective: distribute replicas across AZs and hosts to avoid single points of failure / single-AZ failures.**

- **Operator automatic mode**: Set `topologyZoneKey=topology.kubernetes.io/zone` + `nodeHostnameKey=kubernetes.io/hostname`.
- **Manual mode**: Use `podTemplate.affinity` + `topologySpreadConstraints` + zone / instance-type node selectors.
- **One Pod per host**: `podAntiAffinity` (`requiredDuringSchedulingIgnoredDuringExecution`, topologyKey=`kubernetes.io/hostname`) + `nodeAffinity` (`topology.kubernetes.io/zone`). Official example: `10-zones-02-advanced-02-aws-pod-per-host.yaml`.

Sources:
- https://clickhouse.com/docs/clickhouse-operator/guides/configuration
- https://github.com/Altinity/clickhouse-operator
- https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints
- Altinity "8 developer tricks for running ClickHouse on Kubernetes" (2024-02-27 PDF)

> ⚠️ Minor pitfall: The host label is `kubernetes.io/hostname`, not `topology.kubernetes.io/hostname` (one source states this incorrectly).

---

## V. Quick Start: Official Terraform Blueprint

**Preferred for greenfield deployments: Altinity's open-source Terraform AWS EKS Blueprint (developed in collaboration with the AWS EKS team).**

- One-shot deployment of **EKS + EBS + autoscaling + operator + ClickHouse + Keeper**.
- Reduced to "modify a few lines in the control file + run two Terraform commands."
- Uses **ClickHouse Keeper (not ZooKeeper)** by default.

Sources:
- https://altinity.com/blog/introducing-the-terraform-aws-eks-blueprint-for-clickhouse
- https://github.com/Altinity/terraform-aws-eks-clickhouse

> ⚠️ Note: The README warns that provider versions in the underlying AWS EKS Blueprints module may lag behind; furthermore, the claim that the "blueprint handles backup/recovery" was not substantiated (deployment of the operator is confirmed, but there is no supporting evidence for the scope of backup / recovery).

---

## VI. Explicit Gaps (Insufficiently Covered in This Study — Recommended for Further Investigation)

The following items were explicitly raised in the question but are **not supported by confirmatory evidence**. Do not treat them as resolved:

1. The capabilities / maturity of the **official ClickHouse Operator (released 2026-01)** and how it compares with Altinity's operator — this is critical to the selection decision and requires dedicated research.
2. **Storage selection details**: EBS CSI vs. local NVMe, gp3 IOPS/throughput tuning, volume expansion, `WaitForFirstConsumer` binding, and **the conflict between EBS AZ affinity and cross-AZ replica placement** — one of the easiest pitfalls to encounter with stateful workloads on EKS; this study did not obtain conclusive evidence.
3. **Integration between clickhouse-backup and the operator**: S3 targets, scheduling, recovery procedures, and incremental backups — explicitly raised in the question, but none of the claims survived validation.
4. **K8s pitfalls for stateful workloads**: cross-AZ EBS detach/reattach latency, PVC/StatefulSet rescheduling, rolling upgrade order and replica quorum safety, and recovery from a full disk — unverified and worthy of dedicated research.

---

## Appendix A: Claims Disproven by Adversarial Validation (Negative List)

| Disproven claim | Vote | Explanation |
|---|---|---|
| "The Altinity operator is one of the most popular database operators on GitHub, with >1600 stars" | 1-2 | Outdated; the accurate figure is ~2.5k stars, and the wording is marketing language |
| "Every ClickHouse cluster must reference a Keeper cluster" | 1-2 | Overstated; Keeper is recommended rather than universally mandatory |
| "The blueprint deploys the operator to manage scaling, backup, and recovery" | 1-2 | Operator deployment is confirmed, but the scope of backup/recovery is unsupported |

## Appendix B: Source List (by Perspective)

**broad/primary — operator overview and comparison**
- https://github.com/Altinity/clickhouse-operator (primary)
- https://altinity.com/kubernetes-operator (primary)
- https://pulse.support/kb/clickhouse-kubernetes-operator (blog)
- https://www.tinybird.co/blog/altinity-cloud-managed-clickhouse (blog)

**authoritative refs — vendor and official documentation**
- https://clickhouse.com/docs/cloud/reference/byoc/architecture (primary)
- https://docs.altinity.com/altinitykubernetesoperator (primary)
- https://kb.altinity.com/altinity-kb-setup-and-maintenance/altinity-kb-zookeeper/clickhouse-keeper (primary)
- https://clickhouse.com/blog/building-clickhouse-byoc-on-aws (primary)
- https://altinity.com/blog/whats-new-in-the-altinity-kubernetes-operator-for-clickhouse (blog)

**practitioner/implementation — supporting EKS components**
- https://clickhouse.com/docs/clickhouse-operator/guides/configuration (primary)
- https://altinity.com/webinarspage/all-about-zookeeper-and-clickhouse-keeper-too (secondary)
- https://clickhouse.com/docs/guides/sre/keeper/clickhouse-keeper (primary)
- https://kb.altinity.com/altinity-kb-setup-and-maintenance/altinity-kb-monitoring (primary)

**production best practices — topology, scheduling, and HA**
- https://altinity.com/wp-content/uploads/2024/02/Eureka-8-developer-tricks-for-running-ClickHouse-on-Kubernetes-2024-02-27.pdf (primary)
- https://altinity.com/blog/introducing-the-terraform-aws-eks-blueprint-for-clickhouse (primary)
- https://clickhouse.com/docs/architecture/cluster-deployment (primary)
- https://clickhouse.com/blog/clickhouse-kubernetes-operator (primary)
- https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints (primary)
- https://altinity.com/blog/keeping-clickhouse-open-and-portable-in-altinity-cloud (blog)

**contrarian/skeptical — stateful workload pitfalls**
- https://clickhouse.com/blog/make-before-break-faster-scaling-mechanics-for-clickhouse-cloud (primary)
- https://www.tinybird.co/blog/what-i-learned-operating-clickhouse (blog)
