# ClickHouse on EKS EBS Profile HA and Recovery Drill Report

[中文](./ha-drill-report.md) · **English**

> Drill date: 2026-08-13
> Headline result: the EBS gp3 profile stayed available across pod deletion, graceful eviction, and permanent node loss. Node loss cost 3 seconds of service interruption and required zero data rebuild. The drill also exposed a previously unknown configuration defect: hand-written PDBs overlapped the ones the operator creates automatically, making every ClickHouse pod permanently unevictable. The same defect exists in the production 1×3 manifest.
> Scope: this report covers the **EBS gp3 profile only**. The local-NVMe profile has both replicas in `us-east-1a` and therefore has no cross-AZ failure semantics, so it was not exercised. No local-NVMe HA capability may be inferred from this report.
> Project boundary: the upstream lakehouse holds the single authoritative source of truth. This report validates the acceleration layer's availability and recovery behavior; it does not change the data authority boundary.

## 1. Why the EBS Profile Was Exercised Alone

The [storage selection report](./storage-selection-report.en.md) concludes that EBS gp3 should be the default production profile, partly because EBS allows reattaching the original volume within an AZ and reduces how often a replacement node must be rebuilt. Before this drill that rationale was a **design claim with no measurement behind it** — section 10.5 of that report marks every HA field `TODO` and explicitly forbids inferring recovery capability from query or merge performance.

The goal here was to turn that claim into a measurement: can an EBS volume be reattached to a replacement node after permanent node loss, and what does the process actually cost in availability.

## 2. Topology and Preconditions

| Item | Actual |
|---|---|
| ClickHouse | `25.3.14.14`, 1 shard × 2 replicas |
| Replica AZ placement | `chi-ch-ebs-mainebs-0-0-0` in `us-east-1b`, `0-1-0` in `us-east-1a` |
| Node type | `r8g.4xlarge`, pods at 14 vCPU / 110 GiB |
| Data volumes | one gp3 per replica, 3,400 GiB / 40,000 IOPS / 1,250 MiB/s |
| Keeper | 3 nodes across `us-east-1a` / `1b` / `1c` |
| Dataset | `storage_selection_merge_20260812.hits`, 999,974,970 rows, 130.30 GiB, 1 active part per replica |
| Node group subnets | each EBS node group is pinned to a **single subnet** (one in `us-east-1a`, one in `us-east-1b`) |

**Single-subnet pinning is what makes P8 viable at all.** A gp3 volume is an AZ-scoped resource and cannot be attached across AZs. Because the node group's subnet is fixed in the volume's AZ, a replacement node necessarily lands in that same AZ, which is the only way the volume can be reattached. If a node group spanned several subnets, a replacement node could land in a different AZ, the volume could not attach, and the pod would stay `Pending`. This constraint was verified before the drill.

Pre-drill health: both replicas reported `is_readonly = 0`, `absolute_delay = 0`, `queue_size = 0`, `active_replicas = 2`.

## 3. Measurement Method

Throughout the drill a separate pod (on a `workload: bench` node, distinct from both data replicas) queried the load-balanced `clickhouse-ch-ebs` Service once per second, recording the timestamp, duration, success or failure, and which replica actually served each attempt. The probe ran inside the cluster, so it did not depend on the operator's SSM tunnel staying up.

The query was `SELECT hostName() FROM hits LIMIT 1` with `connect_timeout 2` and `receive_timeout 5`.

> **Measurement boundary:** the probe measures **service continuity for a single lightweight query**, not throughput or tail latency. One-second sampling means interruption duration is resolved to ±1 second and cannot support sub-second SLA claims. Probe success rate is also not equivalent to production availability — real clients have connection pools, retries, and heavier queries.

## 4. P7: Pod Deletion

`chi-ch-ebs-mainebs-0-0-0` was deleted and left to the operator's StatefulSet to heal.

| Metric | Measured |
|---|---:|
| New pod created | t+9s |
| All containers Ready | **t+34s** |
| Failed probe queries | **0** |
| Service interruption | **0s** |
| Replication lag after recovery | 0s |

All 59 probe attempts in the window succeeded. Traffic was carried by the surviving replica while the pod was unavailable (`0-1-0` served 43, `0-0-0` served 16), at p50 44 ms and max 57 ms.

> One measurement trap is worth recording: polling pod status immediately after deletion reads the **terminating old pod** as still `Running:true`, which yields a false "2 second recovery". The start point must be the new pod's `creationTimestamp`; the 34s above is the corrected value.

## 5. P7b: Graceful Eviction (`kubectl drain`)

`kubectl drain` was run against `ip-10-0-1-109`, the node hosting `0-1-0`.

**The first attempt failed:**

```
error when evicting pods/"chi-ch-ebs-mainebs-0-1-0" -n "clickhouse":
This pod has more than one PodDisruptionBudget,
which the eviction subresource does not support.
```

Root cause is in section 7. After removing the redundant PDB:

| Metric | Measured |
|---|---:|
| drain with two PDBs present | **failed** (eviction API refused) |
| drain after removing the redundant PDB | **7s** |
| Failed probe queries | **0** |
| Pod Ready again after uncordon | 20s |

After the drain the node remained cordoned and the pod stayed `Pending`, which is expected — no other schedulable node satisfied its affinity. `kubectl uncordon` restored Ready in 20 seconds.

## 6. P8: Permanent Node Loss

EC2 instance `i-0147e51440dba27ae` (`us-east-1a`), hosting `0-1-0` and the data volume `vol-0c5267f45a1e429f4` (3,400 GiB / 40,000 IOPS / 1,250 MiB/s), was stopped. This is a destructive action with no automatic rollback and was explicitly authorized beforehand.

| Stage | Measured | Note |
|---|---:|---|
| Node became `NotReady` | t+10s | instance entered `stopping` |
| EBS volume detached to `available` | **t+86s** | volume released from the instance |
| Replacement node joined | t+86s | `ip-10-0-1-141`, instance `i-0e8d7d354c0c5754b` |
| Volume reattached, pod `Running` | **t+111s** | mounted at `/dev/xvdaa` |
| Service interruption | **3s** (t+5s to t+7s) | 2 failures out of 260 probe samples |
| Probe availability | **99.2%** | 260 samples at 1s intervals |
| Replication lag after recovery | 0s | |

**The replacement node landed in `us-east-1a`**, the same AZ as the original node and the volume, as the subnet constraint in section 2 predicted.

**Zero data rebuild.** After recovery both replicas reported 999,974,970 rows, 139,911,668,216 bytes, and 1 active part — **byte-identical to the pre-drill state**. The data came from the reattached original volume, not from re-replicating off the healthy replica.

This is the core difference between the EBS profile and local NVMe. When a local-NVMe node is permanently lost, its instance store goes with it and [`recover-local-replica.sh`](../scripts/recover-local-replica.sh) must rebuild roughly 130 GiB from a healthy replica or the lakehouse. On EBS the volume simply reattaches, which took 111 seconds here.

> **Not covered by this drill:** stopping an instance is a **controlled** failure, and AWS detached the volume in an orderly way. Abrupt hardware failure, AZ-level failure, and volume corruption were not tested. The 111 seconds also contains no data rebuild time, because none was needed; if the volume were also lost, the recovery path becomes the same as local NVMe and RTO would be governed by data volume rather than by reattachment.

## 7. The Configuration Defect Found (More Important Than the RTO Numbers)

### 7.1 Symptom

PDB state before the drill:

```
NAME                     MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS
ch-ebs-pdb               2               N/A               0
ch-local-pdb             1               N/A               1
chi-ch-ebs-mainebs       N/A             1                 1
chi-ch-local-mainlocal   N/A             1                 1
```

### 7.2 Two Independent Defects

**Defect 1: overlapping PDBs make pods permanently unevictable.** The Altinity operator automatically creates one PDB per cluster (`chi-<chi>-<cluster>`, `maxUnavailable: 1`). The hand-written PDBs selected the **same pods** via `clickhouse.altinity.com/chi`, creating an overlap. Kubernetes' eviction subresource **refuses any pod covered by more than one PDB**, so every ClickHouse pod was permanently unevictable.

**Defect 2: `minAvailable: 2` on a 2-replica cluster.** `ch-ebs-pdb` required 2 of 2 replicas available, so `ALLOWED DISRUPTIONS` was `0` and eviction would have been blocked even without the overlap.

### 7.3 Blast Radius

Neither defect is limited to drills:

- `kubectl drain` fails indefinitely
- node rolling upgrades and AMI rotation cannot proceed
- Cluster Autoscaler / Karpenter scale-down is blocked
- node replacement during Kubernetes version upgrades is blocked

In short, "highly available" was configured as "unmaintainable".

**The same defect exists in the production 1×3 manifest** [`20-clickhouse-chi.yaml`](../manifests/20-clickhouse-chi.yaml). A 1×3 topology can arithmetically tolerate `minAvailable: 2`, so defect 2 does not apply there; but **defect 1 is independent of replica count**, and an overlapping PDB makes pods permanently unevictable on 1×3 just the same.

### 7.4 Fix

Remove all hand-written PDBs and keep only the operator-managed ones. **The guarantee is not weakened**: the operator's `maxUnavailable: 1` still permits only one replica down at a time, which matches the intent of the hand-written PDBs.

Verified by measurement: drain failed while both PDBs were present, and completed in 7 seconds with zero failed queries once the redundant one was removed.

## 8. Conclusions and Boundaries

**Supported by this drill:**

1. The EBS gp3 profile shows **zero service interruption** under pod deletion and graceful eviction.
2. Controlled permanent node loss cost **3 seconds** of interruption, **111 seconds** to pod `Running`, and **zero data rebuild** — the original volume reattached to a same-AZ replacement node.
3. Replication lag returned to zero after all three failures, with byte-identical data.
4. The design claim that EBS simplifies same-AZ node replacement **now has measured support**.

**Not supported:**

1. **No local-NVMe HA capability may be inferred.** Both of its replicas sit in `us-east-1a` and no fault was injected into that profile. A two-profile HA comparison remains `TODO`.
2. **Not an SLA commitment.** Every figure is from a single drill, with no repeat runs and no confidence intervals. One-second sampling resolution does not support sub-second conclusions.
3. **Failure modes not covered:** AZ-level failure, abrupt hardware failure, volume corruption, Keeper quorum loss, network partition, control-plane failure.
4. **No conclusion about RTO under load.** Only a lightweight probe was running. Injecting the same failure during sustained writes or an active merge could extend recovery substantially.

**Follow-up TODO:**

- Repeat this drill on the local-NVMe profile once it has a symmetric cross-AZ topology, for an apple-to-apple HA comparison
- Repeat P8 under sustained write load to measure RTO under load
- Exercise Keeper quorum loss and AZ-level failure
- Run multiple rounds to produce an RTO distribution rather than single points

**Raw result directory:** `results/ha-ebs/20260813T033253Z` (three probe logs, before/after replica and parts state, volume attachment state, node and pod snapshots). Language-neutral summary: [`perf-results/ha-ebs-20260813-summary.csv`](./perf-results/ha-ebs-20260813-summary.csv).
