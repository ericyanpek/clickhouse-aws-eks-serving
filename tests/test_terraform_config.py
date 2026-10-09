"""Validate actual variable/precondition files with Terraform's built-in provider only."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which("terraform"), "Terraform is required for configuration regression tests")
class TerraformConfigTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.work = Path(cls.temp.name)
        for file in ["variables.tf", "cluster-config.tf"]:
            shutil.copy(ROOT / "terraform" / file, cls.work / file)
        (cls.work / "outputs.tf").write_text(
            'output "zones" { value = { for k, v in local.clickhouse_clusters : k => v.zones } }\n'
        )
        result = cls.tf("init", "-backend=false", "-input=false")
        if result.returncode:
            raise RuntimeError(result.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    @classmethod
    def tf(cls, *args):
        return subprocess.run(
            ["terraform", *args, "-no-color"], cwd=cls.work,
            capture_output=True, text=True, timeout=45,
        )

    def plan(self, values):
        (self.work / "input.tfvars.json").write_text(json.dumps(values))
        return self.tf("plan", "-input=false", "-refresh=false", "-lock=false", "-var-file=input.tfvars.json")

    def test_shipped_example_uses_declared_variables_and_valid_azs(self):
        example = ROOT / "terraform/terraform.tfvars.example"
        result = self.tf("plan", "-input=false", "-refresh=false", "-lock=false", f"-var-file={example}")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("undeclared variable", result.stdout + result.stderr)

    def test_omitted_cluster_zones_follow_another_region(self):
        result = self.plan({
            "region": "eu-west-1",
            "availability_zones": ["eu-west-1a", "eu-west-1b", "eu-west-1c"],
        })
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('"eu-west-1a"', result.stdout)
        self.assertNotIn('"us-east-1a"', result.stdout)

    def test_explicit_foreign_zone_is_rejected(self):
        result = self.plan({"clickhouse_clusters": {"ebs": {
            "zones": ["us-east-1a", "us-east-1b", "us-east-1d"],
        }}})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Every cluster zone", result.stderr)

    def test_fractional_topology_duplicate_zones_and_keeper_underallocation(self):
        cases = [
            {"clickhouse_clusters": {"ebs": {"shards": 1.5, "replicas": 2}}},
            {"availability_zones": ["us-east-1a", "us-east-1a", "us-east-1b"]},
            {"clickhouse_clusters": {"ebs": {"zones": ["us-east-1a"]}}},
            {"region": "eu-west-1"},
        ]
        for values in cases:
            with self.subTest(values=values):
                self.assertNotEqual(self.plan(values).returncode, 0)

    def test_valid_multishard_configuration(self):
        result = self.plan({"clickhouse_clusters": {"ebs": {"shards": 2, "replicas": 3}}})
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
