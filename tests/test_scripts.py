import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]


class ScriptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.config = self.work / "config.json"
        self.log = self.work / "calls.jsonl"
        self.log.touch()
        binary = self.work / "kubectl"
        shutil.copy(ROOT / "tests/fake_kubectl.py", binary)
        binary.chmod(0o755)
        self.env = {
            **os.environ, "PATH": str(self.work) + os.pathsep + os.environ["PATH"],
            "MOCK_CONFIG": str(self.config), "MOCK_LOG": str(self.log),
        }
        for key in ["CLICKHOUSE_NAMESPACE", "CLICKHOUSE_CHI", "CLICKHOUSE_ADMIN_PASSWORD"]:
            self.env.pop(key, None)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def smoke(self, **cfg):
        self.config.write_text(json.dumps(cfg))
        return subprocess.run(
            ["bash", str(ROOT / "scripts/smoke-test.sh")],
            env=self.env, capture_output=True, text=True, timeout=15,
        )

    def recover(self, **cfg):
        self.config.write_text(json.dumps({"mode": "recovery", **cfg}))
        return subprocess.run([
            "bash", str(ROOT / "scripts/recover-local-replica.sh"),
            "chi-nvme-main-1-1-0",
        ], env={
            **self.env, "CLICKHOUSE_NAMESPACE": "ck-nvme", "CONFIRM_REPLICA_DATA_LOSS": "yes",
        }, capture_output=True, text=True, timeout=15)

    def test_smoke_one_shard_all_replicas(self):
        result = self.smoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count("Verified shard="), 3)

    def test_smoke_multishard_and_single_replica(self):
        for shards, replicas in [(2, 3), (3, 1)]:
            with self.subTest(shards=shards, replicas=replicas):
                result = self.smoke(shards=shards, replicas=replicas)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.count("Verified shard="), shards * replicas)

    def test_smoke_repeated_runs_have_separate_databases_and_cleanup(self):
        self.assertEqual(self.smoke().returncode, 0)
        self.assertEqual(self.smoke().returncode, 0)
        queries = [a[a.index("-q") + 1] for a in self.calls() if "-q" in a]
        databases = [q.split()[2] for q in queries if q.startswith("CREATE DATABASE")]
        self.assertEqual(len(set(databases)), 2)
        for database in databases:
            self.assertTrue(any(q.startswith("DROP DATABASE " + database) for q in queries))
        self.assertNotIn("default.t_local", "\n".join(queries))

    def test_incomplete_topology_is_rejected_before_writes(self):
        result = self.smoke(shards=2, missing_host=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any("CREATE DATABASE" in " ".join(a) for a in self.calls()))

    def test_wrong_replica_or_queue_fails_and_cleans_up(self):
        for cfg in [{"bad_replica": True}, {"unhealthy": True}, {"sync_failure": True}]:
            with self.subTest(cfg=cfg):
                self.log.write_text("")
                result = self.smoke(shards=2, **cfg)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(any("DROP DATABASE IF EXISTS" in " ".join(a) for a in self.calls()))
                self.assertNotIn("SMOKE TEST PASSED", result.stdout)

    def test_recovery_scales_statefulset_before_deleting_pvc(self):
        for external in [False, True]:
            with self.subTest(external=external):
                self.log.write_text("")
                result = self.recover(external_pvc=external)
                self.assertEqual(result.returncode, 0, result.stderr)
                calls = self.calls()
                down = next(i for i, a in enumerate(calls)
                            if "statefulset/chi-nvme-main-1-1" in a and "--replicas=0" in a)
                deletion = next(i for i, a in enumerate(calls) if "delete" in a and "pvc" in a)
                self.assertLess(down, deletion)
                self.assertTrue(any("statefulset/chi-nvme-main-1-1" in a and "--replicas=1" in a for a in calls))

    def test_recovery_refuses_healthy_or_ebs_or_wrong_shard(self):
        for cfg in [{"ready": True}, {"node_ready": True}, {"ebs": True}, {"no_same_shard_peer": True}]:
            with self.subTest(cfg=cfg):
                self.log.write_text("")
                result = self.recover(**cfg)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any("scale" in a or "delete" in a for a in self.calls()))

    def test_recovery_restores_controllers_on_failure(self):
        result = self.recover(delete_failure=True)
        self.assertNotEqual(result.returncode, 0)
        calls = self.calls()
        self.assertTrue(any("statefulset/chi-nvme-main-1-1" in a and "--replicas=1" in a for a in calls))
        self.assertTrue(any("deployment/altinity-clickhouse-operator" in a and "--replicas=1" in a for a in calls))

    def test_recovery_requires_explicit_namespace(self):
        result = subprocess.run([
            "bash", str(ROOT / "scripts/recover-local-replica.sh"), "chi-nvme-main-1-1-0",
        ], env={**self.env, "CONFIRM_REPLICA_DATA_LOSS": "yes"}, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])

    def backup(self, fail=False):
        curl = self.work / "curl"
        curl.write_text("""#!/usr/bin/env python3
import os,sys
with open(os.environ["CURL_LOG"],"a") as log:
    log.write(sys.argv[-1]+"\\n")
if os.environ.get("FAIL_SHARD") == "1" and "main-1-0." in sys.argv[-1]:
    sys.exit(22)
""")
        curl.chmod(0o755)
        rendered = (ROOT / "manifests/templates/30-backup-cronjob.yaml.tmpl").read_text()
        for key, value in {"__CLUSTER__": "demo", "__NAMESPACE__": "ck-demo", "__SHARDS__": "3"}.items():
            rendered = rendered.replace(key, value)
        cron = list(yaml.safe_load_all(rendered))[-1]
        command = cron["spec"]["jobTemplate"]["spec"]["template"]["spec"]["containers"][0]["command"]
        log = self.work / "curl.log"
        result = subprocess.run(command, env={
            **self.env, "CURL_LOG": str(log), "POD_UID": "test-uid", "FAIL_SHARD": "1" if fail else "0",
        }, capture_output=True, text=True)
        return result, log.read_text().splitlines()

    def test_backup_covers_all_shards_with_distinct_names(self):
        result, urls = self.backup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(urls), 6)
        names = []
        for shard in range(3):
            create, upload = urls[2 * shard:2 * shard + 2]
            self.assertIn(f"main-{shard}-0.ck-demo", create)
            name = re.search(r"name=([^&]+)", create).group(1)
            names.append(name)
            self.assertIn("/upload/" + name, upload)
            self.assertIn("background=false", upload)
        self.assertEqual(len(set(names)), 3)
        self.assertIn("BACKUP_SET_COMPLETE=", result.stdout)

    def test_partial_backup_fails_without_complete_marker(self):
        result, urls = self.backup(fail=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("BACKUP_SET_COMPLETE=", result.stdout)
        self.assertFalse(any("main-2-0" in u for u in urls))


if __name__ == "__main__":
    unittest.main()
