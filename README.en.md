# ClickHouse on EKS

[中文](./README.md) · **English**

Production-grade ClickHouse cluster on AWS EKS, managed by the Altinity operator, built with Terraform.

## Overview

This repository provisions a complete ClickHouse deployment on AWS EKS:

- **ClickHouse**: 1 shard x 3 replicas (3 pods) on `i8g.4xlarge` nodes (ARM/Graviton) with local NVMe storage
- **ClickHouse Keeper**: 3-node quorum on `gp3-encrypted` EBS volumes, spread across 3 AZs
- **Operator**: Altinity clickhouse-operator v0.27.1, installed as Helm release `altinity-clickhouse-operator` in `kube-system`
- **Infrastructure**: New VPC + EKS cluster built from the Altinity Terraform EKS Blueprint (`//eks` + `//clickhouse-operator` submodules, pinned v0.5.7)
- **Monitoring**: Prometheus + Grafana via `kube-prometheus-stack`
- **Backup**: `clickhouse-backup` sidecar writing to S3 via IRSA (IAM Roles for Service Accounts)
- **Networking**: All ClickHouse services are `ClusterIP` (internal only); access via `kubectl port-forward`

Reference documents:
- [Design spec](docs/superpowers/specs/2026-07-03-clickhouse-on-eks-design.md) — architecture decisions and component choices
- [Research notes](docs/clickhouse-on-eks-research.md) — evaluated alternatives and pinned version rationale

## Prerequisites

| Tool | Version |
|------|---------|
| Terraform | >= 1.5 |
| AWS CLI | any recent; credentials must be configured |
| kubectl | matching target cluster version |
| helm | >= 3 |

**AWS account requirements:**

- Sufficient `i8g.4xlarge` instance quota in your target region (3 instances needed). `i8g` is a Graviton/ARM instance family. Check Service Quotas in the AWS console (`EC2 > Running On-Demand G instances`) and request an increase if needed.
- IAM permissions covering: EKS, VPC/EC2, IAM (role + policy + OIDC provider creation), S3.
- The deploying IAM principal must be able to create IAM roles with `iam:CreateRole`, `iam:AttachRolePolicy`, and `iam:PassRole`.

## Cost Warning

This deployment runs continuously and incurs significant AWS charges:

| Resource | Count | Estimated cost |
|----------|-------|---------------|
| `i8g.4xlarge` (ClickHouse nodes, ARM/Graviton) | 3 | ~$1.35/hr each (approx; confirm current pricing) |
| `t3.medium` (Keeper nodes) | 3 | ~$0.042/hr each |
| `t3.large` (EKS system nodes) | 2 | ~$0.083/hr each |
| NAT Gateway | 1-3 | ~$0.045/hr + data |
| EKS control plane | 1 | $0.10/hr |

**Total: roughly $120-160+ USD per day** (the 3× i8g.4xlarge alone are ~$97/day; larger instances for load testing push this higher). Run `./scripts/teardown.sh` as soon as you are done to stop charges. Do not leave the cluster running unattended.

The S3 backup bucket is NOT deleted by teardown — see [Teardown](#teardown) for manual removal.

## Configure

Edit `terraform/terraform.tfvars` before running anything:

```hcl
# 1. Confirm region and AZs exist in your AWS account
region             = "us-east-1"
availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"]

# 2. S3 bucket name for backups.
backup_bucket_name = ""   # empty = auto-name "<cluster_name>-ch-backups"; set a globally-unique name to override

# 3. SECURITY: restrict to your office/VPN CIDR — do NOT leave world-open in production.
public_access_cidrs = ["203.0.113.0/24"]

# 4. ClickHouse image tag. Default "24.8" is the current LTS (24.8.x).
#    Keeper uses the same tag in manifests/10-keeper-chk.yaml.
#    Check https://clickhouse.com/docs/en/whats-new/changelog for the latest patch.

# 5. Set a Grafana admin password (or change it after first login).
#    If left empty the chart default "prom-operator" is used.
# grafana_admin_password = "set-me"   # uncomment and set, or change after first login (default: prom-operator)
```

Key defaults to be aware of:

- `cluster_name` defaults to `clickhouse-eks` — must be lowercase, alphanumeric + hyphens, max 46 chars.
- `clickhouse_instance_type` defaults to `i8g.4xlarge`. Must be an ARM NVMe instance family (`i8g`, `im4gn`, or `i4g`). Switching to an x86 instance requires also changing `clickhouse_ami_type` (default `AL2023_ARM_64_STANDARD`). Do not change to a non-NVMe type without reworking storage.
- `clickhouse_ami_type` defaults to `AL2023_ARM_64_STANDARD` for Graviton. Change to `AL2023_x86_64_STANDARD` if switching to an x86 instance family.
- `clickhouse_node_count` defaults to `3` (one dedicated node per replica).
- `public_access_cidrs` defaults to `["0.0.0.0/0"]` — world-open. **Restrict this before production.**

**Resource model (dedicated nodes):** Each `i8g.4xlarge` runs exactly one ClickHouse pod. The CHI sets CPU request `"14"` with **no CPU limit** (avoids CFS throttle on bursty queries), and memory request == limit `"110Gi"` (Guaranteed QoS). The `max_server_memory_usage_to_ram_ratio` CHI setting is `"0.9"`, reserving ~10% of RAM for the OS page cache. Verify `110Gi` is below the node's allocatable memory with `kubectl describe node <clickhouse-node>` before applying.

**Load testing:** To run load tests, bump `clickhouse_instance_type` to a larger i8g size (e.g. `i8g.8xlarge` or `i8g.12xlarge`). You must also manually re-tune the CHI CPU/memory resource requests and the data volume size in `manifests/20-clickhouse-chi.yaml` — these values are hand-sized to `i8g.4xlarge` and will be incorrect for other instance sizes.

## Preparing NVMe Disks

AWS AL2023 does **not** automatically format or mount instance store (NVMe) disks. The `local-static-provisioner` that backs the `local-storage` StorageClass expects pre-formatted disks mounted under `/mnt/disks` on each ClickHouse node.

If this is not done before ClickHouse pods are scheduled, the PVCs will remain in `Pending` state.

**You must handle this for your node setup.** Common approaches:

1. **Node bootstrap user-data** — add a shell script to the EKS managed node group launch template that runs on first boot:
   ```bash
   #!/bin/bash
   DISK=/dev/nvme1n1   # adjust device name; i8g.4xlarge has one instance-store NVMe disk (~3.75TB)
   mkdir -p /mnt/disks/nvme1
   if ! blkid "$DISK"; then
     mkfs.xfs -f "$DISK"
   fi
   mount "$DISK" /mnt/disks/nvme1
   echo "$DISK /mnt/disks/nvme1 xfs defaults,nofail 0 2" >> /etc/fstab
   ```
   The exact device path (`/dev/nvme1n1`, `/dev/nvme2n1`, etc.) varies by instance type and AMI. Check `lsblk` on a running node to confirm.

2. **Prep DaemonSet** — deploy a privileged DaemonSet with `hostPID: true` and `hostPath` volume that runs the format+mount before the provisioner runs. This is suitable if you cannot modify the launch template.

After NVMe disks are mounted, the local-static-provisioner will discover them and create `PersistentVolume` objects automatically. Verify with:

```bash
kubectl get pv | grep local-storage
```

## Deploy

Run from the repository root:

```bash
./scripts/deploy.sh
```

What it does (in order):

1. **`terraform init` + `terraform apply`** — creates the VPC, EKS cluster, node groups, Altinity operator (Helm), `local-static-provisioner` (Helm), `kube-prometheus-stack` (Helm), S3 backup bucket, and IRSA role. Terraform will prompt for approval unless you pass `-auto-approve` (suitable only for automation).
2. **Configures kubectl** — runs `aws eks update-kubeconfig` using the `configure_kubectl` Terraform output.
3. **Waits for the operator** — polls `altinity-clickhouse-operator` deployment in `kube-system` for readiness.
4. **Substitutes placeholders** — injects `backup_role_arn`, `backup_bucket`, and `region` (from Terraform outputs) into a temp copy of `manifests/30-backup-cronjob.yaml`. Fails fast if any `REPLACE_WITH_*` placeholder remains.
5. **Applies manifests in dependency order**:
   - `00-namespace.yaml` — creates the `clickhouse` namespace
   - `30-backup-cronjob.yaml` — ServiceAccount (`clickhouse-backup`) + ConfigMap + CronJob. **Must precede the CHI** because the CHI podTemplate references this ServiceAccount.
   - `10-keeper-chk.yaml` — 3-node ClickHouse Keeper; waits up to 5 minutes for readiness
   - `20-clickhouse-chi.yaml` — 1x3 ClickHouse cluster
   - `40-grafana-dashboard.yaml` — Grafana dashboard ConfigMap (placeholder JSON; see [Monitoring](#monitoring))

Watch the rollout:

```bash
kubectl -n clickhouse get chi,chk,pods -w
```

## Set the Admin Password

The CHI ships with an **empty** `admin` password locked to `127.0.0.1/32` (localhost). This is intentional — a bare `kubectl apply` does not expose an open superuser. However, you must set a real password before any meaningful use.

**Step 1: Generate a SHA-256 hash of your password**

```bash
echo -n 'yourpassword' | sha256sum
# example output: 65e84be33532fb784c48129675f9eff3a682b27168c0ea744b2cf58ee02337c5  -
```

**Step 2: Edit `manifests/20-clickhouse-chi.yaml`**

Find the `users` section and update:

```yaml
configuration:
  users:
    admin/password_sha256_hex: "65e84be33532fb784c48129675f9eff3a682b27168c0ea744b2cf58ee02337c5"
    admin/networks/ip: "10.0.0.0/8"   # or your VPC/VPN CIDR; or "0.0.0.0/0,::/0" for any
    admin/profile: default
```

**Step 3: Re-apply**

```bash
kubectl apply -f manifests/20-clickhouse-chi.yaml
```

The operator performs a rolling restart. Watch progress:

```bash
kubectl -n clickhouse get chi ch -w
```

## Verify

After the cluster is fully up (all 3 ClickHouse pods and 3 Keeper pods `Running`):

```bash
./scripts/smoke-test.sh
```

The test:
1. Queries `system.clusters` to confirm the 1x3 topology (1 shard, 3 replicas).
2. Creates `default.t_local` (ReplicatedMergeTree) and `default.t_dist` (Distributed) on all nodes.
3. Inserts 1,000 rows via the distributed table and waits 3 seconds for replication.
4. Reads back from the peer replica of shard 0 to verify cross-replica sync.
5. Reads the distributed count and the replication health from `system.replicas`.

Expected output (the check queries `system.replicas` on a single pod, which reports that
pod's own replica entry — so a healthy result is `replicas registered=1`; the pass condition
is simply count > 0). Cluster-wide replica health is shown by the earlier `system.clusters`
query, which lists all 3 replicas of the shard:

```
==> SMOKE TEST PASSED (distributed count=1000, replicas registered=1)
```

If the test fails, check operator logs and CHI status:

```bash
kubectl -n kube-system logs deploy/altinity-clickhouse-operator -c clickhouse-operator --tail=50
kubectl -n clickhouse describe chi ch
```

## Access

ClickHouse services are `ClusterIP` only. First, find the actual service name:

```bash
kubectl -n clickhouse get svc
```

The Altinity operator names the cluster service after the CHI name; for the CHI named `ch` with cluster `main` the service is typically `clickhouse-ch`. Confirm from the output above, then port-forward:

```bash
# HTTP interface (port 8123)
kubectl -n clickhouse port-forward svc/clickhouse-ch 8123:8123

# In a separate terminal:
curl -u admin:yourpassword "http://localhost:8123/?query=SELECT+version()"
```

For the native TCP interface (port 9000):

```bash
kubectl -n clickhouse port-forward svc/clickhouse-ch 9000:9000
clickhouse-client --host localhost --port 9000 --user admin --password yourpassword
```

To access a specific pod directly (for shard/replica targeting):

```bash
kubectl -n clickhouse port-forward pod/chi-ch-main-0-0 8123:8123
```

## Monitoring

Grafana is deployed in the `monitoring` namespace. Port-forward to access:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
```

Open `http://localhost:3000`. Default credentials: `admin` / `prom-operator` (or the password you set in `terraform.tfvars`).

**Import the ClickHouse Operator dashboard (Grafana.com #12163):**

The file `manifests/40-grafana-dashboard.yaml` ships with a placeholder JSON. Replace it with the real dashboard before applying:

```bash
curl -sL "https://grafana.com/api/dashboards/12163/revisions/latest/download" \
  > /tmp/ch-dashboard.json

# Then either import via the Grafana UI (+ > Import > Upload JSON file)
# or replace the placeholder in the ConfigMap and re-apply:
kubectl -n monitoring create configmap clickhouse-operator-dashboard \
  --from-file=clickhouse-operator.json=/tmp/ch-dashboard.json \
  --dry-run=client -o yaml \
  | kubectl apply -f -
```

Prometheus scrapes ClickHouse metrics exposed by the operator on each pod's `/metrics` endpoint.

## Backup / Restore

### Automated backup

A `CronJob` named `clickhouse-backup-daily` in the `clickhouse` namespace triggers daily at **02:00 UTC**. With a single shard, any replica holds the full dataset, so the CronJob backs up only `chi-ch-main-0-0`, creating a local snapshot then uploading it to the S3 bucket.

Check the last run:

```bash
kubectl -n clickhouse get cronjob clickhouse-backup-daily
kubectl -n clickhouse get jobs | grep backup
```

### Manual backup

Trigger an immediate backup against a specific pod:

```bash
BACKUP="manual-$(date +%Y%m%d-%H%M%S)"
kubectl -n clickhouse port-forward pod/chi-ch-main-0-0 7171:7171 &
curl -sf -X POST "http://localhost:7171/backup/create?name=$BACKUP&background=false"
curl -sf -X POST "http://localhost:7171/backup/upload/$BACKUP?background=false"
```

### Restore

```bash
BACKUP="backup-20260101-020000"   # use the exact name from S3
kubectl -n clickhouse port-forward pod/chi-ch-main-0-0 7171:7171 &
curl -sf -X POST "http://localhost:7171/backup/download/$BACKUP"
curl -sf -X POST "http://localhost:7171/backup/restore/$BACKUP"
```

List available backups:

```bash
curl -s "http://localhost:7171/backup/list"
```

The sidecar REST API reference is at `https://github.com/Altinity/clickhouse-backup#rest-api`.

### Backup bucket

Get the bucket name at any time:

```bash
cd terraform && terraform output -raw backup_bucket
```

The bucket has versioning enabled. It is **not** deleted by `teardown.sh` (to protect against accidental data loss).

## Teardown

```bash
./scripts/teardown.sh
```

Two-phase destruction to avoid orphaned cloud resources:

1. **Delete ClickHouse + Keeper** — the operator cleans up associated PVCs and services.
2. **Targeted Terraform destroy** — destroys in-cluster Helm releases (`kube-prometheus-stack`, `local-static-provisioner`) and the `monitoring` namespace while the EKS API is still reachable. This prevents the Terraform helm/kubernetes provider from hanging on a destroyed cluster.
3. **Full `terraform destroy`** — tears down the EKS cluster, VPC, node groups, IRSA role, and all remaining AWS resources.

After teardown, manually delete the S3 backup bucket if you no longer need the data:

```bash
aws s3 rb "s3://$(cd terraform && terraform output -raw backup_bucket)" --force
```

Note: `terraform output` above requires the Terraform state to still exist. If state was already removed, substitute the bucket name directly.

## Terraform Outputs

| Output | Description |
|--------|-------------|
| `cluster_name` | EKS cluster name |
| `configure_kubectl` | `aws eks update-kubeconfig` command |
| `backup_bucket` | S3 bucket name |
| `backup_role_arn` | IAM role ARN annotated on the `clickhouse-backup` ServiceAccount |
| `clickhouse_namespace` | Kubernetes namespace (`clickhouse`) |
| `region` | AWS region |

Retrieve any output:

```bash
cd terraform && terraform output -raw <output_name>
```

## Known Caveats

- **Local NVMe is ephemeral**: if an `i8g` node is terminated or replaced, the local disk data is lost. ClickHouse recovers by re-syncing the replica from one of the surviving AZ replicas via Keeper. This rebuild can be slow for large datasets (3400Gi per replica). Use the daily S3 backup as an additional safety net.

- **Blueprint provider version locks**: the Altinity EKS Blueprint pins the AWS provider to `~>5.40` and the Helm provider to `<3`. Do not upgrade these without testing against the blueprint modules.

- **`public_access_cidrs` defaults to world-open**: `["0.0.0.0/0"]` exposes the EKS Kubernetes API server publicly. Restrict to your office/VPN CIDR before production use.

- **Admin password must be set before production**: the default CHI configuration ships with an empty password locked to localhost. Follow [Set the Admin Password](#set-the-admin-password) before allowing any application traffic.

- **NVMe mount prep is required**: ClickHouse PVCs will stay `Pending` until instance-store disks are formatted and mounted under `/mnt/disks` on each ClickHouse node. See [Preparing NVMe Disks](#preparing-nvme-disks).

- **No external load balancer by default**: all services are `ClusterIP`. Exposing ClickHouse externally requires adding an `Ingress` or `LoadBalancer` service — this is intentional to reduce the attack surface.
