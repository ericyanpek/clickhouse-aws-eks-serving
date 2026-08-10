# Community and Official Corroboration of This Design's Claims

[中文](./community-corroboration.md) · **English**

> Research date: 2026-07-05. Purpose: to test whether the five core design claims in this proposal are merely "one party's opinion," or whether they are supported by community and official practice.
> Method: searched GitHub, company engineering blogs, conference talks, Hacker News, and official ClickHouse/Altinity content. Every conclusion includes a traceable URL; areas where no corroboration could be found are labeled honestly.
> Position: honesty first, including identifying the choices in this proposal that are "the most opinionated and not the vendor default."

---

## Overview of Corroboration Strength for the Five Claims

| # | Design claim | Corroboration strength | Strongest source |
|---|---|---|---|
| 1 | One shard fills one large machine; scale-up first, shard last | **Strong (the vendor itself says so)** | ClickHouse "at Scale" |
| 2 | Run production ClickHouse on EKS / Kubernetes | **Strong** | ClickHouse LogHouse (19 PiB, running on K8s) |
| 3 | Large memory / one Pod per node / no CPU limit / page-cache awareness | **Strong model; the complete combination must be assembled independently** | Altinity "8 tricks" + oneuptime + Altinity caching guide |
| 4 | Use local NVMe instead of EBS; replicas provide online availability, while the lakehouse provides authoritative durability | **Strong in practice, but not the vendor default** | mrkrbrts.com; Altinity KB EC2 Storage |
| 5 | Treat ClickHouse as a rebuildable serving layer and the upstream lakehouse as the single source of truth | **Strong and now mainstream** | ClickHouse "data lakehouse" Pattern 4; Tinybird |

---

## Claim-by-Claim Corroboration

### Claim 1 — One shard fills a large machine / scale-up first, shard last
**Corroboration: strong. This is almost exactly the position ClickHouse repeatedly emphasizes officially.**

- Official ClickHouse video, "ClickHouse at Scale" — https://www.youtube.com/watch?v=vBjCJtw_Ei0 — exact wording: "scale up is preferred to scale out until the scale up cost becomes more than linear," and "sharding should only be considered if there's the perspective of data volume or data processing speed to exceed the capacity of a single server in the near future." **This is the vendor statement that most closely matches this claim.**
- Official ClickHouse documentation, Table shards and replicas — https://clickhouse.com/docs/shards — positions sharding as a last resort when "the data is too large to fit on one machine" or "one machine is too slow," rather than as the default.
- Altinity webinar, "Deep Dive on ClickHouse Sharding and Replication" — https://altinity.com/webinarspage/deep-dive-on-clickhouse-sharding-and-replication — discusses vertical scaling on a single node first, with sharding as the more difficult subsequent step; it also introduces parallel_replicas as "experimental dynamic sharding" that can defer physical sharding.
- Goutham Veeramachaneni, "Notes on ClickHouse Scaling" — https://www.gouthamve.dev/notes-on-clickhouse-scaling — from a practitioner's perspective, explicitly calls out the pain of re-sharding: "there's no automatic re-sharding. If you add a third shard later, only new data goes to it." This directly corroborates "there is no automatic shard rebalance, so avoid it."
- ClickHouse blog on parallel_replicas — https://clickhouse.com/blog/clickhouse-parallel-replicas — sharding "requires resharding to add capacity, potentially hours or days of work," and parallel replicas are positioned as a way to accelerate a single query without sharding.
  - Honest caveat: under the OSS shared-nothing model, parallel replicas still require every replica to hold a complete copy of the data. They defer sharding but do not eliminate duplicated storage.
- HN, "Ten years of ClickHouse in open source" — https://news.ycombinator.com/item?id=48546890 — one commenter replaced a Druid+Postgres+Trino data warehouse with "one big clickhouse node and I've never looked back."

**Counterargument (honestly noted)**: Instaclustr recommends the opposite — https://www.instaclustr.com/blog/clickhouse-best-practices-part-2-scaling-data-management-and-optimization — "Plan for sharding from the start." Thus, "shard last" is mainstream but not the only position.

### Claim 2 — Run production ClickHouse on EKS / K8s
**Corroboration: strong, including real production write-ups, not just operator documentation.**

- ClickHouse, "How we Built a 19 PiB Logging Platform" (LogHouse) — https://clickhouse.com/blog/building-a-logging-platform-with-clickhouse-and-saving-millions-over-datadog — ClickHouse's own logging platform runs on K8s, orchestrated by an in-house operator; the largest cluster has 5 m5d.16xlarge nodes. Real production.
- Altinity Terraform AWS EKS Blueprint — https://altinity.com/blog/introducing-the-terraform-aws-eks-blueprint-for-clickhouse — a turnkey EKS + operator reference architecture; altinity.cloud has run across 5 clouds on K8s since 2020.
- Altinity operator (GitHub) — https://github.com/altinity/clickhouse-operator — "manages tens of thousands of ClickHouse servers worldwide"; publicly listed adopters include MUX and Infovista.
- Official ClickHouse Kubernetes Operator — https://clickhouse.com/blog/clickhouse-kubernetes-operator — ClickHouse Inc's own operator; K8s is a first-class deployment target.
- Shamsul Arefin (Medium) — https://medium.com/@shamsul.arefin/evaluating-the-performance-of-clickhouse-with-amplab-big-data-benchmark-dataset-on-kubernetes-b36e860ba027 — hands-on EKS + Altinity operator + instance-store NVMe deployment (also corroborates Claims 3 and 4).

### Claim 3 — Large memory / one Pod per node / no CPU limit / page-cache awareness
**Corroboration: the resource model is strong; the complete "no CPU limit + one Pod per node" combination is assembled from multiple sources.**

- Altinity, "Eureka! 8 developer tricks for running ClickHouse on Kubernetes" (PDF) — https://altinity.com/wp-content/uploads/2024/02/Eureka-8-developer-tricks-for-running-ClickHouse-on-Kubernetes-2024-02-27.pdf — confirms the StatefulSet model of "one pod per stateful set," pinning Pods to specific VMs with nodeSelector/instance-type labels, and retaining PVCs. This directly supports one Pod per node + dedicated-node sizing.
- oneuptime, "Resource Requests and Limits for ClickHouse on Kubernetes" — https://oneuptime.com/blog/post/2026-03-31-clickhouse-resource-requests-limits-k8s/view — recommends setting the memory request to 50–80% of node RAM, and says to "consider omitting CPU limits for query-intensive deployments" — exactly the "no CPU limit" position.
- Altinity, "Caching in ClickHouse — Definitive Guide Part 1" — https://altinity.com/blog/caching-in-clickhouse-the-definitive-guide-part-1 — page-cache-aware sizing: "queries typically use less than 50% of available RAM, leaving the rest for the OS page cache."
- ClickHouse OSS usage tips — https://clickhouse.com/docs/operations/tips — "use a reasonable amount of RAM (128 GB or more) so the hot data subset will fit in the cache of pages."
- ClickHouse sizing/hardware recommendations — https://clickhouse.com/docs/guides/sizing-and-hardware-recommendations — real configuration example: 256 GB RAM per replica, 4–6 GB RAM/vCPU.

**Honest gap**: no authoritative document was found that packages "one Pod per node + no CPU limit + large memory + page-cache awareness" into a single checklist. This proposal systematically assembles those scattered practices, which is itself the incremental value.

### Claim 4 — Use local NVMe instead of EBS; replicas provide online availability, while the lakehouse provides authoritative durability
**Corroboration: strong as a practice, but there is an important honest caveat about OSS durability semantics.**

- Mark Roberts, "How to run a cost-efficient ClickHouse cluster with separated storage & compute" — https://mrkrbrts.com/blog/how-to-run-a-cost-efficient-clickhouse-cluster-with-separated-storage-and-compute — the closest match. It advocates ephemeral local NVMe instance store (the r7gd family) as a write-through cache, with durable S3 as the fallback, running on EKS + Altinity operator + local-volume-provisioner, saving about 40%. It directly confronts the ephemeral nature: "the elephant in the room is that these disks are ephemeral... how can we make this safe?" → S3 durability.
- Altinity KB, "AWS EC2 Storage" — https://kb.altinity.com/altinity-kb-setup-and-maintenance/aws-ec2-storage — important caveat: "ClickHouse doesn't have any native option to reuse the same data on durable network disk via several replicas. You either need to store the same data twice or build custom tooling." That is: online redundancy from replicas requires N complete copies on local disks; authoritative durability remains the responsibility of the upstream lakehouse.
- AWS storage-optimized instance families — https://aws.amazon.com/ec2/instance-types/i3en — confirms that the i3/i3en/i4i/i4g local NVMe families are purpose-built targets; this proposal's i8g/im4gn belong to the same lineage.
- anthonynsimon, "1-Node ClickHouse in Production" — https://anthonynsimon.com/blog/clickhouse-deployment — single-node CH on local NVMe, "on plain EC2 and on Kubernetes."
- Severalnines, "ClickHouse Storage Architecture and Optimization" — https://severalnines.com/blog/clickhouse-storage-architecture-and-optimization — "SSD or NVMe disks as the preferred foundation for production."

**Honest caveat**: ClickHouse's official sizing guide recommends provisioned-IOPS EBS rather than instance store. Thus, "local disk instead of EBS" is an intentional choice by cost-oriented practitioners, not the vendor default; and using OSS replicas for online availability means N complete local copies.

### Claim 5 — Treat ClickHouse as a rebuildable serving layer and the upstream lakehouse as the single source of truth
**Corroboration: strong and increasingly mainstream. ClickHouse Inc and Tinybird have explicitly documented it as an architectural pattern.**

- ClickHouse Inc, "What is a data lakehouse?" — https://clickhouse.com/resources/engineering/data-lakehouse — Pattern 4 is precisely this claim: "Data is initially written to Iceberg or Delta Lake tables (the source of truth)... incrementally replicated to ClickHouse... Lakehouse maintains full history."
- Tinybird, "Apache Iceberg with ClickHouse" — https://www.tinybird.co/blog/clickhouse-apache-iceberg-integration — "Keep Iceberg as your source of truth... use ClickHouse (with periodic copies) as the query engine... This is the pattern Tinybird uses." A real vendor operates this way.
- GlassFlow — https://www.glassflow.dev/blog/blog-data-lakes-apache-iceberg-clickhouse-data-transformation — "Iceberg as the 'Cold' Layer / Source of Truth... ClickHouse as the 'Hot' Layer."
- BigDataBoutique — https://bigdataboutique.com/blog/clickhouse-and-apache-iceberg-practical-guide-to-data-lakehouse-integration — recommends ingesting into native MergeTree for latency-sensitive queries and reserving direct Iceberg access for ad hoc queries.
- OLake — https://olake.io/blog/build-data-lakehouse-iceberg-clickhouse-olake — an end-to-end MySQL→CDC→Iceberg(S3)→ClickHouse serving-layer build.

---

## Practices Closest to This Proposal's Combined Philosophy (Matching at Least 3 Claims)

Ordered by number of matching claims:

1. **Mark Roberts — "cost-efficient ClickHouse with separated storage & compute"**
   https://mrkrbrts.com/blog/how-to-run-a-cost-efficient-clickhouse-cluster-with-separated-storage-and-compute
   Matches **2 + 4 + 5 (implicitly 3)**. EKS + Altinity operator + ephemeral local NVMe + durable S3 + replica HA. **The person with the most similar "same idea."** Key difference: he uses S3 as the primary disk + NVMe as cache; this project defines the upstream lakehouse as the sole SoT, uses NVMe-derived replicas in ClickHouse, and uses a separate S3 backup bucket only to shorten recovery time.

2. **OpenMetal case study — ClickHouse deployment on bare metal + OpenStack + Ceph**
   https://openmetal.io/resources/case-studies/architecture-big-data-clickhouse-deployment
   Matches **1 + 3 + 4 + 5**. Real production (a cybersecurity company): 6 bare-metal machines, 1 TB RAM each, about 268 TiB of local Micron NVMe as the "hot tier," and S3-compatible Ceph as the "cold/historical" tier. Large dedicated nodes + local NVMe + object-storage fallback all at once. **The named real-world production case closest to Claims 3–5.**

3. **ClickHouse LogHouse (the vendor itself)**
   https://clickhouse.com/blog/building-a-logging-platform-with-clickhouse-and-saving-millions-over-datadog
   Matches **1 + 2 + 3 + 4**. K8s + in-house operator + m5d.16xlarge (local NVMe) + 200 GiB RAM/node + no sharding within a single cluster. The vendor itself runs large-node, local-disk K8s.

4. **Altinity "8 developer tricks" deck** (+ companion "Kubernetes Storage" deck)
   https://altinity.com/wp-content/uploads/2024/02/Eureka-8-developer-tricks-for-running-ClickHouse-on-Kubernetes-2024-02-27.pdf
   Firmly matches **2 + 3**, and foreshadows 4/5 ("Where we are going next: Object storage for sure, using NVMe SSD for local cache"). This is the core Altinity K8s operations guide cited by this repository's research.

---

## Conclusion

- **Claims 1, 2, and 5 are essentially mainstream/vendor-endorsed.**
- **Claim 3 has strong support item by item, but the complete combination must be assembled independently** — the systematization in this proposal is the incremental value.
- **Claim 4 (local disk instead of EBS) is the most opinionated choice** — strongly supported by cost-oriented practitioners + one strong bare-metal production case (OpenMetal), but explicitly not ClickHouse Inc's default recommendation; replicas are only responsible for online redundancy and require N complete local copies, while authoritative data recovery still depends on the lakehouse.

**In one sentence**: this proposal is not novelty for novelty's sake; it systematically assembles practices that are "vendor-endorsed (1/2/5) + community-backed but not default (3/4)" into reviewable IaC. Moreover, no public implementation packages all five into turnkey EKS IaC — mrkrbrts is a blog, OpenMetal is a bare-metal case study, and LogHouse is internal to the vendor. **This repository fills exactly that gap.**
