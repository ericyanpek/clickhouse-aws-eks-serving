# Documentation Index

[中文](./README.md) · **English**

This page records the authority, language, and scope of each repository document so historical designs and test environments are not mistaken for the current implementation.

## Canonical Entry Points

| Document | Status |
|---|---|
| [`README.md`](../README.md) / [`README.en.md`](../README.en.md) | Current canonical Chinese and English entry points; both must be maintained in sync |

The two root READMEs must retain the same section numbering, commands, versions, topology, recovery model, and project boundaries. Every user-visible behavioral change must update both files.

## Supporting Artifacts

| Chinese | English | Status and purpose |
|---|---|---|
| [`clickhouse-on-eks-research.md`](./clickhouse-on-eks-research.md) | [`clickhouse-on-eks-research.en.md`](./clickhouse-on-eks-research.en.md) | Point-in-time ecosystem research; version information may age |
| [`community-corroboration.md`](./community-corroboration.md) | [`community-corroboration.en.md`](./community-corroboration.en.md) | External examples and evidence for the design claims |
| [`notes-ck-on-eks-best-practices-2026.md`](./notes-ck-on-eks-best-practices-2026.md) | [`notes-ck-on-eks-best-practices-2026.en.md`](./notes-ck-on-eks-best-practices-2026.en.md) | Architecture reasoning that defines the lakehouse as the sole SoT |
| [`perf-testing-plan.md`](./perf-testing-plan.md) | [`perf-testing-plan.en.md`](./perf-testing-plan.en.md) | Test plan for the current 1×3 target |
| [`perf-test-report.md`](./perf-test-report.md) | [`perf-test-report.en.md`](./perf-test-report.en.md) | **Historical 1×2 measurements**, not current 1×3 results |
| [`storage-comparison-results.md`](./storage-comparison-results.md) | [`storage-comparison-results.en.md`](./storage-comparison-results.en.md) | **Historical 1×2 EBS-only measurements from 2026-08-11**, including Apple-to-Apple limits and CloudWatch evidence |
| [`storage-selection-report.md`](./storage-selection-report.md) | [`storage-selection-report.en.md`](./storage-selection-report.en.md) | **Same-run local-NVMe versus EBS selection experiment from 2026-08-12**; query, CloudWatch, merge-timing, and merge-window device-level I/O results are recorded, with the EBS profile's HA drill covered in the HA report |
| [`ha-drill-report.md`](./ha-drill-report.md) | [`ha-drill-report.en.md`](./ha-drill-report.en.md) | **EBS profile HA and recovery drill from 2026-08-13**; measured RTO for pod deletion, graceful eviction, and permanent node loss, plus the overlapping-PDB defect that made pods unevictable. Does not cover the local-NVMe profile |
| [`superpowers/specs/2026-07-03-clickhouse-on-eks-design.md`](./superpowers/specs/2026-07-03-clickhouse-on-eks-design.md) | [`superpowers/specs/2026-07-03-clickhouse-on-eks-design.en.md`](./superpowers/specs/2026-07-03-clickhouse-on-eks-design.en.md) | Current design background; implementation and the root READMEs take precedence |
| [`superpowers/plans/2026-07-03-clickhouse-on-eks.md`](./superpowers/plans/2026-07-03-clickhouse-on-eks.md) | [`superpowers/plans/2026-07-03-clickhouse-on-eks.en.md`](./superpowers/plans/2026-07-03-clickhouse-on-eks.en.md) | **Historical implementation record** containing obsolete 2×2/i4i steps; not an operations guide |

`perf-results/multi-cluster-verify-20260817-summary.csv`, `perf-results/clickbench-43queries.csv`, `perf-results/ebs-gp3-clickbench-43queries.csv`, `perf-results/ebs-gp3-qps-summary.csv`, `perf-results/storage-selection-20260812-summary.csv`, and `perf-results/ha-ebs-20260813-summary.csv` contain only language-neutral field names and values, so each remains a single file. [`perf-results/qps-by-query-type.txt`](./perf-results/qps-by-query-type.txt), whose group labels are Chinese, has a matching [`English version`](./perf-results/qps-by-query-type.en.txt).

## Project Invariants

The following facts must remain consistent across all current documentation:

1. The data lakehouse holds the sole authoritative Source of Truth (SoT); ClickHouse is its derived, eventually consistent, rebuildable OLAP acceleration layer.
2. The current target is 1 shard × 3 replicas; the performance report's 1×2 figures may only be cited as historical measurements.
3. The ClickHouse and Keeper images are pinned to 25.3 LTS, and the operator is pinned to 0.27.1.
4. Permanent local-NVMe node loss requires an operator-triggered local-PV recovery procedure; recovery is not fully automatic.
5. The S3 backup bucket is only a ClickHouse recovery point, not the lakehouse SoT; teardown retains it outside Terraform state.
6. This repository does not implement the lakehouse, Kafka/Flink pipelines, or ClickHouse Cloud/OSS dual-write.

## Synchronization Rules

- Markdown files without a language suffix are Chinese; `.en.md` files are English.
- Every document must provide bidirectional Chinese/English navigation directly below its H1.
- Both versions must retain the same section structure, code blocks, commands, URLs, numbers, versions, and technical conclusions.
- Run `./scripts/check-docs.sh` before committing documentation changes.
