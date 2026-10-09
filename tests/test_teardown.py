import argparse
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "teardown", Path(__file__).resolve().parents[1] / "scripts/teardown.py"
)
td = importlib.util.module_from_spec(spec)
spec.loader.exec_module(td)

IDENTITY = {
    "name": "custom-eks", "account": "123456789012", "region": "eu-west-1",
    "endpoint": "https://THIS.eks.amazonaws.com", "ca": "dGVzdC1jYQ==",
}


def state():
    return {
        "lineage": "sample-lineage",
        "outputs": {
            "clickhouse_cluster_names": {"value": ["ebs", "ebs-cold"]},
            "backup_bucket": {"value": "retained-backups"},
            "aws_profile": {"value": "sample-profile"},
        },
        "resources": [{
            "mode": "managed", "type": "aws_eks_cluster",
            "instances": [{"attributes": {
                "name": IDENTITY["name"],
                "arn": f"arn:aws:eks:{IDENTITY['region']}:{IDENTITY['account']}:cluster/{IDENTITY['name']}",
                "endpoint": IDENTITY["endpoint"],
                "certificate_authority": [{"data": IDENTITY["ca"]}],
            }}],
        }],
    }


class Commands:
    def __init__(self):
        self.state = state()
        self.calls = []
        self.account = IDENTITY["account"]
        self.cluster = {
            "server": IDENTITY["endpoint"], "certificate-authority-data": IDENTITY["ca"],
        }
        self.pvs = {"items": [
            {"metadata": {"name": "pv-own"}, "spec": {
                "claimRef": {"namespace": "ck-ebs"},
                "csi": {"driver": "ebs.csi.aws.com", "volumeHandle": "vol-aaa"},
            }},
            {"metadata": {"name": "pv-other"}, "spec": {
                "claimRef": {"namespace": "ck-ebs-cold"},
                "csi": {"driver": "ebs.csi.aws.com", "volumeHandle": "vol-bbb"},
            }},
        ]}
        self.fail_delete = False
        self.fail_kube = False
        self.addresses = [
            'aws_eks_node_group.clickhouse["ebs-eu-west-1a"]',
            'aws_eks_node_group.clickhouse["ebs-cold-eu-west-1a"]',
            'kubernetes_storage_class.clickhouse_gp3["ebs"]',
            'aws_iam_role.backup["ebs"]',
            'aws_iam_role_policy.backup_s3["ebs"]',
            'aws_s3_bucket.backup',
            'module.eks.kubernetes_storage_class.gp3-encrypted',
        ]

    def __call__(self, args, *, allow_error=False):
        self.calls.append(args)
        text, code, error = "", 0, ""
        if args[0] == "terraform":
            if args[2:] == ["state", "pull"]:
                text = json.dumps(self.state)
            elif args[2:] == ["state", "list"]:
                text = "\n".join(self.addresses)
        elif args[0] == "aws":
            if "get-caller-identity" in args:
                text = json.dumps({"Account": self.account})
            elif "delete-volume" in args and self.fail_delete:
                code, error = 1, "UnauthorizedOperation"
            elif "describe-volumes" in args:
                raise AssertionError("Account-wide volume discovery is forbidden")
        elif args[0] == "kubectl":
            if self.fail_kube:
                raise RuntimeError("Kubernetes API unavailable")
            if "current-context" in args:
                text = "selected-context"
            elif "view" in args:
                text = json.dumps(self.cluster)
            elif "pv" in args:
                text = json.dumps(self.pvs)
            elif "get" in args and "namespace" in args:
                text = "namespace/ck-ebs"
        return subprocess.CompletedProcess(args, code, text, error)

    def mutations(self):
        return [c for c in self.calls if any(
            a in c for a in ["delete", "delete-volume", "delete-role", "delete-role-policy", "destroy", "rm"]
        )]


class TeardownTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.commands = Commands()
        self.root = Path(self.temp.name)
        self.patches = [
            patch.object(td, "ROOT", self.root),
            patch.object(td, "run", self.commands),
        ]
        for p in self.patches:
            p.start()
            self.addCleanup(p.stop)

    def prepare(self, cluster="ebs", aws_only=False):
        return td.Teardown(argparse.Namespace(cluster=cluster, aws_only=aws_only))

    def test_exact_ids_and_targets_only_for_selected_cluster(self):
        self.prepare().execute()
        deleted = [c[c.index("--volume-id") + 1] for c in self.commands.calls if "delete-volume" in c]
        self.assertEqual(deleted, ["vol-aaa"])
        destroys = [c for c in self.commands.calls if "destroy" in c]
        self.assertTrue(destroys)
        self.assertNotIn("ebs-cold", json.dumps(destroys))
        for command in self.commands.calls:
            if command[0] == "aws":
                self.assertEqual(command[1:5], ["--region", "eu-west-1", "--profile", "sample-profile"])
        self.assertIn("custom-eks-ck-ebs-backup", json.dumps(self.commands.calls))

    def test_wrong_cluster_stops_before_mutation(self):
        self.commands.cluster["server"] = "https://OTHER.eks.amazonaws.com"
        with self.assertRaisesRegex(RuntimeError, "context does not match"):
            self.prepare()
        self.assertEqual(self.commands.mutations(), [])

    def test_wrong_account_stops_before_mutation(self):
        self.commands.account = "999999999999"
        with self.assertRaisesRegex(RuntimeError, "account"):
            self.prepare()
        self.assertEqual(self.commands.mutations(), [])

    def test_failed_discovery_does_not_destroy_infrastructure(self):
        self.commands.fail_kube = True
        with self.assertRaisesRegex(RuntimeError, "unavailable"):
            self.prepare()
        self.assertEqual(self.commands.mutations(), [])

    def test_unknown_namespace_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, "not owned"):
            self.prepare("foreign")
        self.assertEqual(self.commands.mutations(), [])

    def test_interrupted_deletion_preserves_ids_even_after_pvs_disappear(self):
        first = self.prepare()
        self.commands.fail_delete = True
        with self.assertRaisesRegex(RuntimeError, "Could not delete"):
            first.execute()
        self.assertFalse(any("destroy" in c for c in self.commands.calls))
        saved = json.loads(first.path.read_text())
        self.assertEqual(saved["volumes"]["ck-ebs"], ["vol-aaa"])
        self.commands.pvs = {"items": []}
        self.commands.fail_delete = False
        second = self.prepare()
        self.assertEqual(second.journal["volumes"]["ck-ebs"], ["vol-aaa"])
        second.execute()

    def test_aws_only_requires_prior_inventory(self):
        with self.assertRaisesRegex(RuntimeError, "captured"):
            self.prepare(cluster=None, aws_only=True)
        self.assertEqual(self.commands.mutations(), [])

    def test_aws_only_resumes_after_eks_disappears_without_kubectl(self):
        first = self.prepare(cluster=None)
        self.commands.calls.clear()
        self.commands.state["resources"] = []
        resumed = self.prepare(cluster=None, aws_only=True)
        resumed.execute()
        self.assertFalse(any(c[0] == "kubectl" for c in self.commands.calls))
        destroy = next(i for i, c in enumerate(self.commands.calls) if "destroy" in c)
        delete = next(i for i, c in enumerate(self.commands.calls) if "delete-volume" in c)
        self.assertLess(destroy, delete)
        self.assertFalse(first.path.exists())

    def test_recreated_eks_cannot_reuse_old_inventory(self):
        self.prepare()
        self.commands.state["resources"][0]["instances"][0]["attributes"]["endpoint"] = "https://NEW.eks.amazonaws.com"
        with self.assertRaisesRegex(RuntimeError, "differs"):
            self.prepare()
        self.assertEqual(self.commands.mutations(), [])

    def test_ssm_tunnel_requires_matching_ca_and_tls_name(self):
        cluster = {
            "server": "https://127.0.0.1:8443",
            "tls-server-name": "this.eks.amazonaws.com",
            "certificate-authority-data": IDENTITY["ca"],
        }
        td.verify_kube_cluster(cluster, IDENTITY)
        cluster["certificate-authority-data"] = "other"
        with self.assertRaises(RuntimeError):
            td.verify_kube_cluster(cluster, IDENTITY)

    def test_pv_inventory_ignores_unrelated_namespaces_and_drivers(self):
        pvs = copy.deepcopy(self.commands.pvs)
        pvs["items"][0]["spec"]["csi"]["driver"] = "other.csi"
        self.assertEqual(td.volume_handles(pvs, {"ck-ebs"}), {"ck-ebs": []})


if __name__ == "__main__":
    unittest.main()
