#!/usr/bin/env python3
"""Offline CLI fixture: never contacts Kubernetes or AWS."""
import json
import os
from pathlib import Path
import re
import sys

a = sys.argv[1:]
cfg = json.loads(Path(os.environ["MOCK_CONFIG"]).read_text())
with open(os.environ["MOCK_LOG"], "a") as log:
    log.write(json.dumps(a) + "\n")
q = a[a.index("-q") + 1] if "-q" in a else ""
query_path = " ".join(a)

if cfg.get("mode", "smoke") == "smoke":
    shards, replicas = cfg.get("shards", 1), cfg.get("replicas", 3)
    if "get" in a and "pods" in a:
        print("chi-ebs-main-0-0-0")
    elif "get" in a and "chi" in a:
        print(shards if "shardsCount" in query_path else replicas)
    elif "FROM system.clusters" in q:
        for s in range(1, shards + 1):
            for r in range(1, replicas + 1):
                if cfg.get("missing_host") and (s, r) == (shards, replicas):
                    continue
                print(f"{s}\t{r}\thost-{s}-{r}")
    elif "SYSTEM SYNC REPLICA" in q:
        if cfg.get("sync_failure"):
            sys.exit(1)
    elif "sum(cityHash64(v))" in q:
        host = a[a.index("--host") + 1]
        s, r = map(int, host.split("-")[1:])
        # Deliberately uneven shard counts: a test must not require 1000 per shard.
        rows = 1000 + (100 if s == 1 and shards > 1 else -100 if s == 2 else 0)
        if cfg.get("bad_replica") and r == replicas:
            rows += 1
        print(f"{rows}\t{s * 10000}\t{s * 123456}")
    elif "FROM system.replicas" in q:
        print("1\t1" if cfg.get("unhealthy") else "1\t0")
    elif "uniqExact(id)" in q:
        rows = shards * 1000
        print(f"{rows}\t{rows}\t{rows * (rows - 1) // 2}")
    elif q.startswith(("CREATE ", "INSERT ", "DROP ")):
        pass
    else:
        raise AssertionError(a)
else:
    pod = "chi-nvme-main-1-1-0"
    sts = pod.rsplit("-", 1)[0]
    pvc = "ch-data-" + pod
    if "delete" in a and "pvc" in a and cfg.get("delete_failure"):
        sys.exit(1)
    elif any(action in a for action in ["scale", "delete", "rollout", "wait"]):
        pass
    elif "get" in a and "pod" in a:
        if a[a.index("pod") + 1] != pod:
            sys.exit(1)
        if "Ready" in query_path:
            print("True" if cfg.get("ready") else "False")
        elif ".spec.nodeName" in query_path:
            print("failed-node")
        elif "persistentVolumeClaim" in query_path:
            print(pvc)
    elif "get" in a and "node" in a:
        print("True" if cfg.get("node_ready") else "False")
    elif "get" in a and "pvc" in a:
        if "storageClassName" in query_path:
            print("gp3" if cfg.get("ebs") else "local-storage")
        elif "/chi" in query_path:
            print("nvme")
        elif "/shard" in query_path:
            print("1")
        elif "/cluster" in query_path:
            print("main")
        elif "volumeName" in query_path:
            print("pv-lost")
    elif "get" in a and "pods" in a:
        assert "clickhouse.altinity.com/shard=1" in query_path
        if not cfg.get("no_same_shard_peer"):
            print("chi-nvme-main-1-0-0\tTrue")
    elif "get" in a and "statefulset" in a:
        template = {"spec": {"volumes": []}}
        claims = [{"metadata": {"name": "ch-data"}}]
        if cfg.get("external_pvc"):
            template["spec"]["volumes"] = [{"persistentVolumeClaim": {"claimName": pvc}}]
            claims = []
        print(json.dumps({
            "metadata": {"name": sts, "labels": {"clickhouse.altinity.com/chi": "nvme"}},
            "spec": {"replicas": 1, "volumeClaimTemplates": claims, "template": template},
        }))
    elif "get" in a and any(x.startswith("deployment/") for x in a):
        print("1")
    else:
        raise AssertionError(a)
