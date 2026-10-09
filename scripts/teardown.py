#!/usr/bin/env python3
"""Delete only resources identified by this Terraform state and its EKS cluster."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlparse


ROOT = Path(__file__).resolve().parents[1]
KEY_RE = r"[a-z0-9](?:[a-z0-9-]{0,18}[a-z0-9])?"


def run(args, *, allow_error=False):
    result = subprocess.run(args, cwd=ROOT, text=True, capture_output=True)
    if result.returncode and not allow_error:
        raise RuntimeError(f"{args[0]} failed: {result.stderr.strip()}")
    return result


def tf(*args, **kwargs):
    return run(["terraform", "-chdir=terraform", *args], **kwargs)


def state_instances(state):
    for resource in state.get("resources", []):
        for instance in resource.get("instances", []):
            if not instance.get("deposed"):
                yield resource, instance.get("attributes", {})


def deployment_identity(state):
    """Use the state, never the active kubectl context or AWS_REGION, as authority."""
    identities = []
    for resource, attrs in state_instances(state):
        if resource["type"] != "aws_eks_cluster" or not attrs.get("arn"):
            continue
        arn = attrs["arn"].split(":")
        identities.append({
            "name": attrs["name"],
            "account": arn[4],
            "region": arn[3],
            "endpoint": attrs["endpoint"],
            "ca": attrs["certificate_authority"][0]["data"],
        })
    if not identities:
        return None
    if any(identity != identities[0] for identity in identities):
        raise RuntimeError("Terraform state contains more than one EKS identity.")
    return identities[0]


def managed_namespaces(state):
    names = set()
    outputs = state.get("outputs", {})
    for key in outputs.get("clickhouse_cluster_names", {}).get("value", []):
        if re.fullmatch(KEY_RE, key):
            names.add(f"ck-{key}")
    for resource, attrs in state_instances(state):
        if resource["type"] == "aws_eks_node_group":
            key = (attrs.get("labels") or {}).get("ck-cluster", "")
            if re.fullmatch(KEY_RE, key):
                names.add(f"ck-{key}")
    return names


def verify_kube_cluster(cluster, identity):
    endpoint = identity["endpoint"].rstrip("/")
    # SSM tunnels use localhost but preserve the actual EKS TLS server name.
    same_server = cluster.get("server", "").rstrip("/") == endpoint
    tunnel = (
        urlparse(cluster.get("server", "")).hostname in {"127.0.0.1", "localhost", "::1"}
        and cluster.get("tls-server-name") == urlparse(endpoint).hostname
    )
    if (
        cluster.get("insecure-skip-tls-verify")
        or cluster.get("certificate-authority-data") != identity["ca"]
        or not (same_server or tunnel)
    ):
        raise RuntimeError("kubectl context does not match the EKS endpoint and CA in Terraform state.")


def volume_handles(pvs, namespaces):
    volumes = {ns: [] for ns in namespaces}
    for pv in pvs.get("items", []):
        spec = pv.get("spec", {})
        ns = (spec.get("claimRef") or {}).get("namespace")
        csi = spec.get("csi") or {}
        if ns not in volumes or csi.get("driver") != "ebs.csi.aws.com":
            continue
        volume = csi.get("volumeHandle", "")
        if not re.fullmatch(r"vol-[0-9a-f]+", volume):
            raise RuntimeError(f"Unexpected EBS volume handle on PV {pv['metadata']['name']}.")
        volumes[ns].append(volume)
    return volumes


def save_journal(path, journal):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(journal, stream, indent=2, sort_keys=True)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


class Teardown:
    def __init__(self, args):
        self.args = args
        self.state = json.loads(tf("state", "pull").stdout)
        lineage = self.state.get("lineage", "")
        if not re.fullmatch(r"[a-zA-Z0-9-]+", lineage):
            raise RuntimeError("Terraform state has no valid lineage; refusing unscoped teardown.")
        self.path = ROOT / ".teardown" / f"{lineage}.json"
        self.journal = json.loads(self.path.read_text()) if self.path.exists() else {}
        identity = deployment_identity(self.state)
        if identity is None:
            if not args.aws_only or not self.journal.get("captured"):
                raise RuntimeError("No EKS identity in state. Resuming requires --aws-only and a captured journal.")
            identity = self.journal["identity"]
        if self.journal and self.journal["identity"] != identity:
            raise RuntimeError("EKS identity differs from the saved journal; resolve the old deployment first.")
        self.identity = identity
        outputs = self.state.get("outputs", {})
        profile = outputs.get("aws_profile", {}).get("value")
        self.aws_options = ["--region", identity["region"]]
        if profile:
            self.aws_options += ["--profile", profile]
        caller = json.loads(self.aws("sts", "get-caller-identity").stdout)
        if caller["Account"] != identity["account"]:
            raise RuntimeError("AWS credentials do not belong to the account in Terraform state.")

        self.namespaces = managed_namespaces(self.state) | set(self.journal.get("volumes", {}))
        if args.cluster:
            requested = f"ck-{args.cluster}"
            if requested not in self.namespaces:
                raise RuntimeError(f"{requested} is not owned by this Terraform state or journal.")
            self.namespaces = {requested}
        if args.aws_only:
            if not self.journal.get("captured"):
                raise RuntimeError("--aws-only requires volume IDs captured by an earlier verified run.")
            missing = self.namespaces - set(self.journal["volumes"])
            if missing:
                raise RuntimeError(f"Journal has no volume inventory for {sorted(missing)}.")
        else:
            self.context = run(["kubectl", "config", "current-context"]).stdout.strip()
            cluster = json.loads(self.kube(
                "config", "view", "--minify", "--flatten", "--raw",
                "-o", "jsonpath={.clusters[0].cluster}",
            ).stdout)
            verify_kube_cluster(cluster, identity)
            discovered = volume_handles(
                json.loads(self.kube("get", "pv", "-o", "json").stdout), self.namespaces
            )
            # Capture every selected namespace before the first delete. Retrying
            # after PVC/PV deletion retains the old exact IDs; never scan by tags.
            recorded = self.journal.setdefault("volumes", {})
            for ns, ids in discovered.items():
                recorded[ns] = sorted(set(recorded.get(ns, [])) | set(ids))
            self.journal["captured"] = True
        self.journal.update({
            "identity": identity,
            "backup_bucket": outputs.get("backup_bucket", {}).get(
                "value", self.journal.get("backup_bucket", "")
            ),
        })
        save_journal(self.path, self.journal)

    def aws(self, *args, **kwargs):
        return run(["aws", *self.aws_options, *args], **kwargs)

    def kube(self, *args, **kwargs):
        return run(["kubectl", "--context", self.context, *args], **kwargs)

    def delete_namespace(self, ns):
        exists = self.kube("get", "namespace", ns, "--ignore-not-found", "-o", "name")
        if not exists.stdout.strip():
            return
        for kind, selector in [
            ("chi", "clickhouse.altinity.com/app=chop"),
            ("chk", "app=clickhouse-keeper"),
        ]:
            self.kube("-n", ns, "delete", kind, "--all", "--ignore-not-found", "--timeout=600s")
            pods = self.kube("-n", ns, "get", "pods", "-l", selector, "-o", "name")
            if pods.stdout.strip():
                self.kube("-n", ns, "wait", "--for=delete", *pods.stdout.split(), "--timeout=600s")
        self.kube("-n", ns, "delete", "pvc", "--all", "--ignore-not-found", "--timeout=300s")
        self.kube("delete", "namespace", ns, "--ignore-not-found", "--timeout=300s")

    def delete_volumes(self, ns):
        for volume in list(self.journal["volumes"].get(ns, [])):
            print(f"Deleting recorded EBS volume {volume} ({ns})", flush=True)
            for attempt in range(6):
                response = self.aws("ec2", "delete-volume", "--volume-id", volume, allow_error=True)
                if response.returncode == 0 or "InvalidVolume.NotFound" in response.stderr:
                    self.journal["volumes"][ns].remove(volume)
                    save_journal(self.path, self.journal)
                    break
                if "VolumeInUse" not in response.stderr or attempt == 5:
                    raise RuntimeError(
                        f"Could not delete {volume}; journal retained for retry: {response.stderr.strip()}"
                    )
                time.sleep(10)

    def state_addresses(self):
        return tf("state", "list").stdout.splitlines()

    def forget(self, addresses):
        for address in addresses:
            tf("state", "rm", address)

    def destroy_one(self):
        key = self.args.cluster
        az = r"[a-z]{2}-[a-z]+-[0-9]+[a-z]"
        pattern = (
            rf'(?:kubernetes_storage_class\.clickhouse_gp3\["{re.escape(key)}"\]'
            rf'|aws_eks_node_group\.(?:clickhouse|keeper)\["{re.escape(key)}-{az}"\])'
        )
        targets = [a for a in self.state_addresses() if re.fullmatch(pattern, a)]
        if targets:
            tf("destroy", "-auto-approve", *[f"-target={a}" for a in targets])
        # Avoid destroy -target on IAM resources: dependencies can select other clusters.
        role = f"{self.identity['name']}-ck-{key}-backup"
        for operation, extra in [
            ("delete-role-policy", ["--policy-name", "s3-access"]),
            ("delete-role", []),
        ]:
            response = self.aws("iam", operation, "--role-name", role, *extra, allow_error=True)
            if response.returncode and "NoSuchEntity" not in response.stderr:
                raise RuntimeError(response.stderr.strip())
        addresses = set(self.state_addresses())
        self.forget(a for a in [
            f'aws_iam_role_policy.backup_s3["{key}"]', f'aws_iam_role.backup["{key}"]'
        ] if a in addresses)

    def destroy_all(self):
        retain = {
            "aws_s3_bucket.backup",
            "aws_s3_bucket_versioning.backup",
            "aws_s3_bucket_server_side_encryption_configuration.backup",
            "aws_s3_bucket_public_access_block.backup",
        }
        self.forget(a for a in self.state_addresses() if a in retain or re.search(
            r"(?:^|\.)(?:helm_release|kubernetes_[a-z_]+)\.", a
        ))
        response = tf("destroy", "-auto-approve", allow_error=True)
        if response.returncode:
            print("Terraform destroy failed; retrying once.", flush=True)
            tf("destroy", "-auto-approve")

    def execute(self):
        print(f"Verified deployment: {self.identity['account']}/{self.identity['region']}/{self.identity['name']}")
        print(f"Volume cleanup journal: {self.path}", flush=True)
        if not self.args.aws_only:
            for ns in sorted(self.namespaces):
                self.delete_namespace(ns)
                self.delete_volumes(ns)
        if self.args.cluster:
            self.destroy_one()
            self.journal["volumes"].pop(f"ck-{self.args.cluster}", None)
            save_journal(self.path, self.journal)
            print(f"Remove '{self.args.cluster}' from clickhouse_clusters before the next apply.")
        else:
            self.destroy_all()
            # When the API is unavailable, terminate the nodes first, then reclaim
            # only volumes captured in a previous run against the verified cluster.
            for ns in sorted(self.namespaces):
                self.delete_volumes(ns)
            self.path.unlink()
            print(f"Retained S3 backup bucket: {self.journal['backup_bucket']}")
        print("Teardown complete.", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cluster", help="Delete only this ClickHouse cluster key.")
    parser.add_argument("--aws-only", action="store_true",
                        help="Resume full teardown without Kubernetes using a previously captured volume journal.")
    args = parser.parse_args()
    if args.cluster and not re.fullmatch(KEY_RE, args.cluster):
        parser.error("invalid cluster key")
    if args.aws_only and args.cluster:
        parser.error("--aws-only supports full teardown only")
    try:
        Teardown(args).execute()
    except (RuntimeError, ValueError, KeyError, OSError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
