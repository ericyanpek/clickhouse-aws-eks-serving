#!/usr/bin/env python3
"""Analyze one storage-selection benchmark result directory."""

from __future__ import annotations

import argparse
import csv
import json
import re
import sys
from collections import defaultdict
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
from pathlib import Path
from statistics import median
from typing import Any, Iterable


SCHEMA_VERSION = 1
ROUND_DIGITS = 6
QUANTUM = Decimal("1").scaleb(-ROUND_DIGITS)
PROFILES = ("local_nvme", "ebs_gp3")
QPS_FILE_RE = re.compile(
    r"^qps-(?P<profile>local_nvme|ebs_gp3)-(?P<workload>.+)-c(?P<concurrency>\d+)\.(?:txt|log)$"
)
MERGE_QPS_FILE_RE = re.compile(
    r"^qps-during-merge-(?P<profile>local_nvme|ebs_gp3)\.(?:txt|log)$"
)
NUMBER = r"[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?"
SUMMARY_LINE_RE = re.compile(
    rf"queries:\s*(?P<queries>\d+),\s*QPS:\s*(?P<qps>{NUMBER}),\s*"
    rf"RPS:\s*(?P<rps>{NUMBER}),\s*MiB/s:\s*(?P<mib>{NUMBER}),\s*"
    rf"result RPS:\s*(?P<result_rps>{NUMBER}),\s*"
    rf"result MiB/s:\s*(?P<result_mib>{NUMBER})",
    re.IGNORECASE,
)
PERCENTILE_RE = re.compile(rf"^\s*(?P<pct>\d+(?:\.\d+)?)%\s+(?P<seconds>{NUMBER})\s+sec\.", re.MULTILINE)
QUERIES_EXECUTED_RE = re.compile(r"Queries executed:\s*(\d+)", re.IGNORECASE)
ERROR_RE = re.compile(r"(?:Errors|Failed queries|Queries failed):\s*(\d+)", re.IGNORECASE)
DISK_HEADER = (
    "epoch",
    "node",
    "device",
    "model",
    "reads",
    "sectors_read",
    "read_ms",
    "writes",
    "sectors_written",
    "write_ms",
    "io_ms",
    "weighted_io_ms",
)
DISK_INT_FIELDS = DISK_HEADER[:3] + DISK_HEADER[4:]


def decimal_value(value: object) -> Decimal | None:
    if value is None:
        return None
    text = str(value).strip()
    if not text:
        return None
    try:
        result = Decimal(text)
    except InvalidOperation:
        return None
    return result if result.is_finite() else None


def json_number(value: Decimal | int | None) -> int | float | None:
    if value is None:
        return None
    if isinstance(value, int):
        return value
    rounded = value.quantize(QUANTUM, rounding=ROUND_HALF_UP)
    if rounded == rounded.to_integral():
        return int(rounded)
    return float(rounded)


def percent_change(candidate: Decimal | None, baseline: Decimal | None) -> int | float | None:
    if candidate is None or baseline is None or baseline == 0:
        return None
    return json_number((candidate - baseline) * Decimal(100) / baseline)


def ratio(candidate: Decimal | None, baseline: Decimal | None) -> int | float | None:
    if candidate is None or baseline is None or baseline == 0:
        return None
    return json_number(candidate / baseline)


def mean(values: list[Decimal]) -> Decimal | None:
    if not values:
        return None
    return sum(values, Decimal(0)) / Decimal(len(values))


def decimal_median(values: list[Decimal]) -> Decimal | None:
    if not values:
        return None
    return Decimal(str(median(values)))


def nearest_rank(values: list[Decimal], percentile: int) -> Decimal | None:
    if not values:
        return None
    ordered = sorted(values)
    rank = (len(ordered) * percentile + 99) // 100
    return ordered[max(rank - 1, 0)]


def relative(path: Path, root: Path) -> str:
    return path.relative_to(root).as_posix()


def read_csv(path: Path) -> tuple[list[dict[str, str]], list[str]]:
    warnings: list[str] = []
    try:
        with path.open("r", encoding="utf-8-sig", newline="") as handle:
            reader = csv.DictReader(handle)
            if not reader.fieldnames:
                return [], ["CSV has no header"]
            rows = []
            for line_number, row in enumerate(reader, start=2):
                if None in row:
                    warnings.append(f"line {line_number}: extra columns ignored")
                    row.pop(None, None)
                rows.append({str(key).strip(): (value or "").strip() for key, value in row.items()})
            return rows, warnings
    except (OSError, UnicodeError, csv.Error) as exc:
        return [], [f"could not read CSV: {exc}"]


def comparison(
    metric: str,
    baseline: Decimal | None,
    candidate: Decimal | None,
    *,
    lower_is_better: bool,
) -> dict[str, Any]:
    return {
        "metric": metric,
        "baseline_profile": "local_nvme",
        "candidate_profile": "ebs_gp3",
        "baseline": json_number(baseline),
        "candidate": json_number(candidate),
        "candidate_vs_baseline_pct": percent_change(candidate, baseline),
        "candidate_to_baseline_ratio": ratio(candidate, baseline),
        "lower_is_better": lower_is_better,
    }


def analyze_clickbench(root: Path, warnings: list[str]) -> dict[str, Any]:
    files = sorted(root.rglob("clickbench.csv"), key=lambda path: relative(path, root))
    if not files:
        return {"status": "missing", "files": [], "groups": [], "comparisons": []}

    records: list[dict[str, Any]] = []
    file_summaries: list[dict[str, Any]] = []
    for path in files:
        rows, file_warnings = read_csv(path)
        rel = relative(path, root)
        warnings.extend(f"{rel}: {message}" for message in file_warnings)
        accepted = 0
        for line_number, row in enumerate(rows, start=2):
            profile = row.get("profile", "")
            mode = row.get("mode", "")
            qid = row.get("qid", "")
            best = decimal_value(row.get("best_s"))
            if not profile or not mode or not qid or best is None:
                warnings.append(f"{rel}: line {line_number}: invalid ClickBench row skipped")
                continue
            run_values = []
            for key in sorted(row):
                if re.fullmatch(r"run\d+_s", key):
                    value = decimal_value(row[key])
                    if value is not None:
                        run_values.append(json_number(value))
            records.append(
                {
                    "source": rel,
                    "profile": profile,
                    "mode": mode,
                    "qid": qid,
                    "best_seconds": best,
                    "run_seconds": run_values,
                }
            )
            accepted += 1
        file_summaries.append({"path": rel, "rows": len(rows), "accepted_rows": accepted})

    grouped: dict[tuple[str, str, str], list[dict[str, Any]]] = defaultdict(list)
    for record in records:
        dataset = str(Path(record["source"]).parent)
        grouped[(dataset, record["profile"], record["mode"])].append(record)

    groups: list[dict[str, Any]] = []
    group_values: dict[tuple[str, str, str], dict[str, Decimal]] = {}
    for key in sorted(grouped):
        dataset, profile, mode = key
        rows = sorted(grouped[key], key=lambda item: (item["qid"], item["source"]))
        values = [item["best_seconds"] for item in rows]
        metrics = {
            "total_best_seconds": sum(values, Decimal(0)),
            "mean_best_seconds": mean(values),
            "median_best_seconds": decimal_median(values),
            "p90_best_seconds": nearest_rank(values, 90),
            "p95_best_seconds": nearest_rank(values, 95),
            "p99_best_seconds": nearest_rank(values, 99),
        }
        group_values[key] = {name: value for name, value in metrics.items() if value is not None}
        groups.append(
            {
                "dataset": dataset,
                "profile": profile,
                "mode": mode,
                "query_count": len(values),
                **{name: json_number(value) for name, value in metrics.items()},
            }
        )

    comparisons: list[dict[str, Any]] = []
    dimensions = sorted({(dataset, mode) for dataset, _, mode in grouped})
    for dataset, mode in dimensions:
        local = group_values.get((dataset, "local_nvme", mode))
        ebs = group_values.get((dataset, "ebs_gp3", mode))
        if local is None or ebs is None:
            continue
        for metric in (
            "total_best_seconds",
            "mean_best_seconds",
            "median_best_seconds",
            "p90_best_seconds",
            "p95_best_seconds",
            "p99_best_seconds",
        ):
            comparisons.append(
                {
                    "dataset": dataset,
                    "mode": mode,
                    **comparison(metric, local.get(metric), ebs.get(metric), lower_is_better=True),
                }
            )

    by_query: dict[tuple[str, str, str, str], Decimal] = {}
    for record in records:
        dataset = str(Path(record["source"]).parent)
        by_query[(dataset, record["mode"], record["qid"], record["profile"])] = record["best_seconds"]
    query_comparisons = []
    query_dimensions = sorted({key[:3] for key in by_query})
    for dataset, mode, qid in query_dimensions:
        local = by_query.get((dataset, mode, qid, "local_nvme"))
        ebs = by_query.get((dataset, mode, qid, "ebs_gp3"))
        if local is None or ebs is None:
            continue
        query_comparisons.append(
            {
                "dataset": dataset,
                "mode": mode,
                "qid": qid,
                **comparison("best_seconds", local, ebs, lower_is_better=True),
            }
        )

    return {
        "status": "present" if records else "empty",
        "files": file_summaries,
        "groups": groups,
        "comparisons": comparisons,
        "query_comparisons": query_comparisons,
    }


def parse_qps_file(path: Path, root: Path, warnings: list[str]) -> dict[str, Any]:
    rel = relative(path, root)
    regular = QPS_FILE_RE.match(path.name)
    during_merge = MERGE_QPS_FILE_RE.match(path.name)
    if regular:
        profile = regular.group("profile")
        workload = regular.group("workload")
        concurrency: int | None = int(regular.group("concurrency"))
    elif during_merge:
        profile = during_merge.group("profile")
        workload = "during_merge"
        concurrency = None
    else:
        return {}

    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        warnings.append(f"{rel}: could not read QPS log: {exc}")
        return {
            "source": rel,
            "profile": profile,
            "workload": workload,
            "concurrency": concurrency,
            "status": "unreadable",
        }

    summaries = list(SUMMARY_LINE_RE.finditer(text))
    summary = summaries[-1] if summaries else None
    if summary is None:
        warnings.append(f"{rel}: final clickhouse-benchmark summary line not found")

    percentile_values: dict[str, Decimal] = {}
    for match in PERCENTILE_RE.finditer(text):
        percentile_values[match.group("pct")] = Decimal(match.group("seconds"))
    if not percentile_values:
        warnings.append(f"{rel}: latency percentiles not found")

    executed = QUERIES_EXECUTED_RE.findall(text)
    errors = ERROR_RE.findall(text)
    result: dict[str, Any] = {
        "source": rel,
        "profile": profile,
        "workload": workload,
        "concurrency": concurrency,
        "status": "parsed" if summary else "partial",
        "queries_executed": int(executed[-1]) if executed else None,
        "errors": int(errors[-1]) if errors else None,
        "latency_seconds": {
            f"p{percentile.replace('.', '_')}": json_number(value)
            for percentile, value in sorted(percentile_values.items(), key=lambda item: Decimal(item[0]))
        },
    }
    if summary:
        result.update(
            {
                "queries": int(summary.group("queries")),
                "qps": json_number(Decimal(summary.group("qps"))),
                "rps": json_number(Decimal(summary.group("rps"))),
                "mib_per_second": json_number(Decimal(summary.group("mib"))),
                "result_rps": json_number(Decimal(summary.group("result_rps"))),
                "result_mib_per_second": json_number(Decimal(summary.group("result_mib"))),
            }
        )
    else:
        result.update(
            {
                "queries": None,
                "qps": None,
                "rps": None,
                "mib_per_second": None,
                "result_rps": None,
                "result_mib_per_second": None,
            }
        )
    return result


def analyze_qps(root: Path, warnings: list[str]) -> dict[str, Any]:
    paths = sorted(
        (
            path
            for path in root.rglob("*")
            if path.is_file() and (QPS_FILE_RE.match(path.name) or MERGE_QPS_FILE_RE.match(path.name))
        ),
        key=lambda path: relative(path, root),
    )
    if not paths:
        return {"status": "missing", "runs": [], "comparisons": []}

    runs = [parsed for path in paths if (parsed := parse_qps_file(path, root, warnings))]
    indexed = {
        (run["workload"], run["concurrency"], run["profile"]): run
        for run in runs
        if run["status"] != "unreadable"
    }
    dimensions = sorted(
        {(workload, concurrency) for workload, concurrency, _ in indexed},
        key=lambda item: (item[0], -1 if item[1] is None else item[1]),
    )
    comparisons: list[dict[str, Any]] = []
    for workload, concurrency in dimensions:
        local = indexed.get((workload, concurrency, "local_nvme"))
        ebs = indexed.get((workload, concurrency, "ebs_gp3"))
        if local is None or ebs is None:
            continue
        for metric, lower_is_better in (
            ("qps", False),
            ("rps", False),
            ("mib_per_second", False),
        ):
            comparisons.append(
                {
                    "workload": workload,
                    "concurrency": concurrency,
                    **comparison(
                        metric,
                        decimal_value(local.get(metric)),
                        decimal_value(ebs.get(metric)),
                        lower_is_better=lower_is_better,
                    ),
                }
            )
        percentiles = sorted(
            set(local.get("latency_seconds", {})) & set(ebs.get("latency_seconds", {}))
        )
        for percentile in percentiles:
            comparisons.append(
                {
                    "workload": workload,
                    "concurrency": concurrency,
                    **comparison(
                        f"latency_seconds.{percentile}",
                        decimal_value(local["latency_seconds"][percentile]),
                        decimal_value(ebs["latency_seconds"][percentile]),
                        lower_is_better=True,
                    ),
                }
            )

    return {
        "status": "present" if runs else "empty",
        "runs": runs,
        "comparisons": comparisons,
    }


def analyze_load(root: Path, warnings: list[str]) -> dict[str, Any]:
    files = sorted(root.rglob("load-seconds.csv"), key=lambda path: relative(path, root))
    if not files:
        return {"status": "missing", "files": [], "groups": [], "comparisons": []}

    records: list[dict[str, Any]] = []
    file_summaries = []
    for path in files:
        rows, file_warnings = read_csv(path)
        rel = relative(path, root)
        warnings.extend(f"{rel}: {message}" for message in file_warnings)
        accepted = 0
        for line_number, row in enumerate(rows, start=2):
            profile = row.get("profile", "")
            insert_seconds = decimal_value(row.get("insert_seconds"))
            ready_seconds = decimal_value(row.get("replicas_ready_seconds"))
            if not profile or (insert_seconds is None and ready_seconds is None):
                warnings.append(f"{rel}: line {line_number}: invalid load timing row skipped")
                continue
            records.append(
                {
                    "source": rel,
                    "dataset": str(path.parent.relative_to(root)),
                    "profile": profile,
                    "copy_index": row.get("copy_index") or None,
                    "insert_seconds": insert_seconds,
                    "replicas_ready_seconds": ready_seconds,
                }
            )
            accepted += 1
        file_summaries.append({"path": rel, "rows": len(rows), "accepted_rows": accepted})

    grouped: dict[tuple[str, str], list[dict[str, Any]]] = defaultdict(list)
    for record in records:
        grouped[(record["dataset"], record["profile"])].append(record)
    groups = []
    values_by_group: dict[tuple[str, str], dict[str, Decimal | None]] = {}
    for key in sorted(grouped):
        dataset, profile = key
        insert_values = [
            record["insert_seconds"] for record in grouped[key] if record["insert_seconds"] is not None
        ]
        ready_values = [
            record["replicas_ready_seconds"]
            for record in grouped[key]
            if record["replicas_ready_seconds"] is not None
        ]
        metrics = {
            "total_insert_seconds": sum(insert_values, Decimal(0)) if insert_values else None,
            "mean_insert_seconds": mean(insert_values),
            "total_replicas_ready_seconds": sum(ready_values, Decimal(0)) if ready_values else None,
            "mean_replicas_ready_seconds": mean(ready_values),
        }
        values_by_group[key] = metrics
        groups.append(
            {
                "dataset": dataset,
                "profile": profile,
                "samples": len(grouped[key]),
                **{name: json_number(value) for name, value in metrics.items()},
            }
        )

    comparisons = []
    for dataset in sorted({key[0] for key in grouped}):
        local = values_by_group.get((dataset, "local_nvme"))
        ebs = values_by_group.get((dataset, "ebs_gp3"))
        if local is None or ebs is None:
            continue
        for metric in (
            "total_insert_seconds",
            "mean_insert_seconds",
            "total_replicas_ready_seconds",
            "mean_replicas_ready_seconds",
        ):
            comparisons.append(
                {
                    "dataset": dataset,
                    **comparison(metric, local[metric], ebs[metric], lower_is_better=True),
                }
            )

    return {
        "status": "present" if records else "empty",
        "files": file_summaries,
        "groups": groups,
        "comparisons": comparisons,
    }


def analyze_merge(root: Path, warnings: list[str]) -> dict[str, Any]:
    path = root / "merge-final.csv"
    if not path.is_file():
        return {"status": "missing", "source": None, "runs": [], "comparisons": []}
    rows, file_warnings = read_csv(path)
    rel = relative(path, root)
    warnings.extend(f"{rel}: {message}" for message in file_warnings)
    runs = []
    values: dict[str, Decimal] = {}
    for line_number, row in enumerate(rows, start=2):
        profile = row.get("profile", "")
        seconds = decimal_value(row.get("optimize_seconds"))
        if not profile or seconds is None:
            warnings.append(f"{rel}: line {line_number}: invalid merge timing row skipped")
            continue
        runs.append({"profile": profile, "optimize_seconds": json_number(seconds)})
        values[profile] = seconds
    comparisons = []
    if "local_nvme" in values and "ebs_gp3" in values:
        comparisons.append(
            comparison(
                "optimize_seconds",
                values["local_nvme"],
                values["ebs_gp3"],
                lower_is_better=True,
            )
        )
    return {
        "status": "present" if runs else "empty",
        "source": rel,
        "runs": sorted(runs, key=lambda item: item["profile"]),
        "comparisons": comparisons,
    }


def strip_kubectl_prefix(line: str) -> str:
    marker = line.find("epoch\tnode\tdevice\tmodel\t")
    if marker >= 0:
        return line[marker:]
    match = re.search(r"(?P<data>\d{9,}\t[^\t]+\t[^\t]+\t.*)$", line)
    return match.group("data") if match else line


def classify_disk(model: str) -> str | None:
    normalized = model.lower()
    if "elastic block store" in normalized or normalized.strip() == "amazon ebs":
        return "ebs_gp3"
    if "instance storage" in normalized:
        return "local_nvme"
    return None


def parse_disk_file(path: Path, root: Path, warnings: list[str]) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    rel = relative(path, root)
    samples: list[dict[str, Any]] = []
    invalid_lines = 0
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError as exc:
        warnings.append(f"{rel}: could not read disk counter log: {exc}")
        return [], {"path": rel, "lines": 0, "samples": 0, "invalid_lines": 0}
    for line_number, raw_line in enumerate(lines, start=1):
        line = strip_kubectl_prefix(raw_line).strip()
        if not line or line.startswith("epoch\t"):
            continue
        fields = line.split("\t")
        if len(fields) < len(DISK_HEADER):
            invalid_lines += 1
            continue
        fields = fields[-len(DISK_HEADER) :]
        row = dict(zip(DISK_HEADER, fields))
        try:
            for field in DISK_INT_FIELDS:
                if field in ("node", "device"):
                    continue
                row[field] = int(row[field])
        except ValueError:
            invalid_lines += 1
            warnings.append(f"{rel}: line {line_number}: invalid disk counter row skipped")
            continue
        row["source"] = rel
        row["profile"] = classify_disk(str(row["model"]))
        samples.append(row)
    return samples, {
        "path": rel,
        "lines": len(lines),
        "samples": len(samples),
        "invalid_lines": invalid_lines,
    }


def disk_device_summary(
    key: tuple[str, str, str, str | None], samples: list[dict[str, Any]]
) -> tuple[dict[str, Any], int]:
    source, node, device, profile = key
    ordered = sorted(samples, key=lambda row: row["epoch"])
    deduplicated: dict[int, dict[str, Any]] = {}
    for sample in ordered:
        deduplicated[sample["epoch"]] = sample
    ordered = [deduplicated[epoch] for epoch in sorted(deduplicated)]

    totals = defaultdict(int)
    valid_duration = 0
    reset_intervals = 0
    peak_read_mib = Decimal(0)
    peak_write_mib = Decimal(0)
    peak_read_iops = Decimal(0)
    peak_write_iops = Decimal(0)
    peak_busy = Decimal(0)
    fields = (
        "reads",
        "sectors_read",
        "read_ms",
        "writes",
        "sectors_written",
        "write_ms",
        "io_ms",
        "weighted_io_ms",
    )
    for previous, current in zip(ordered, ordered[1:]):
        duration = current["epoch"] - previous["epoch"]
        deltas = {field: current[field] - previous[field] for field in fields}
        if duration <= 0 or any(value < 0 for value in deltas.values()):
            reset_intervals += 1
            continue
        valid_duration += duration
        for field, value in deltas.items():
            totals[field] += value
        seconds = Decimal(duration)
        read_mib = Decimal(deltas["sectors_read"] * 512) / Decimal(1024**2) / seconds
        write_mib = Decimal(deltas["sectors_written"] * 512) / Decimal(1024**2) / seconds
        read_iops = Decimal(deltas["reads"]) / seconds
        write_iops = Decimal(deltas["writes"]) / seconds
        busy = Decimal(deltas["io_ms"]) / (seconds * Decimal(1000)) * Decimal(100)
        peak_read_mib = max(peak_read_mib, read_mib)
        peak_write_mib = max(peak_write_mib, write_mib)
        peak_read_iops = max(peak_read_iops, read_iops)
        peak_write_iops = max(peak_write_iops, write_iops)
        peak_busy = max(peak_busy, busy)

    duration_decimal = Decimal(valid_duration) if valid_duration else None
    summary = {
        "source": source,
        "node": node,
        "device": device,
        "model": ordered[-1]["model"] if ordered else None,
        "profile": profile,
        "sample_count": len(ordered),
        "valid_interval_count": max(len(ordered) - 1 - reset_intervals, 0),
        "counter_reset_intervals": reset_intervals,
        "duration_seconds": valid_duration if valid_duration else None,
        "read_ios": totals["reads"] if valid_duration else None,
        "write_ios": totals["writes"] if valid_duration else None,
        "read_bytes": totals["sectors_read"] * 512 if valid_duration else None,
        "write_bytes": totals["sectors_written"] * 512 if valid_duration else None,
        "average_read_mib_per_second": json_number(
            Decimal(totals["sectors_read"] * 512) / Decimal(1024**2) / duration_decimal
            if duration_decimal
            else None
        ),
        "average_write_mib_per_second": json_number(
            Decimal(totals["sectors_written"] * 512) / Decimal(1024**2) / duration_decimal
            if duration_decimal
            else None
        ),
        "average_read_iops": json_number(
            Decimal(totals["reads"]) / duration_decimal if duration_decimal else None
        ),
        "average_write_iops": json_number(
            Decimal(totals["writes"]) / duration_decimal if duration_decimal else None
        ),
        "average_busy_pct": json_number(
            Decimal(totals["io_ms"]) / (duration_decimal * Decimal(1000)) * Decimal(100)
            if duration_decimal
            else None
        ),
        "peak_interval_read_mib_per_second": json_number(peak_read_mib) if valid_duration else None,
        "peak_interval_write_mib_per_second": json_number(peak_write_mib) if valid_duration else None,
        "peak_interval_read_iops": json_number(peak_read_iops) if valid_duration else None,
        "peak_interval_write_iops": json_number(peak_write_iops) if valid_duration else None,
        "peak_interval_busy_pct": json_number(peak_busy) if valid_duration else None,
    }
    return summary, reset_intervals


def analyze_disk_counters(root: Path, warnings: list[str]) -> dict[str, Any]:
    paths = sorted(root.rglob("disk-counters*.tsv"), key=lambda path: relative(path, root))
    if not paths:
        return {
            "status": "missing",
            "files": [],
            "analysis_source": None,
            "devices": [],
            "profile_aggregates": [],
            "comparisons": [],
        }

    parsed_by_path: dict[Path, list[dict[str, Any]]] = {}
    file_summaries = []
    for path in paths:
        samples, file_summary = parse_disk_file(path, root, warnings)
        parsed_by_path[path] = samples
        file_summaries.append(file_summary)

    preferred = next((path for path in paths if path.name == "disk-counters-all.tsv"), None)
    if preferred is None:
        preferred = max(paths, key=lambda path: (len(parsed_by_path[path]), relative(path, root)))
    samples = parsed_by_path[preferred]
    grouped: dict[tuple[str, str, str, str | None], list[dict[str, Any]]] = defaultdict(list)
    for sample in samples:
        grouped[(sample["source"], sample["node"], sample["device"], sample["profile"])].append(sample)

    devices = []
    reset_count = 0
    for key in sorted(grouped, key=lambda item: tuple("" if value is None else value for value in item)):
        summary, resets = disk_device_summary(key, grouped[key])
        devices.append(summary)
        reset_count += resets
    if reset_count:
        warnings.append(
            f"{relative(preferred, root)}: skipped {reset_count} disk counter interval(s) after a reset"
        )

    aggregate_metrics = (
        "average_read_mib_per_second",
        "average_write_mib_per_second",
        "average_read_iops",
        "average_write_iops",
    )
    profile_aggregates = []
    aggregate_values: dict[str, dict[str, Decimal]] = {}
    for profile in PROFILES:
        profile_devices = [device for device in devices if device["profile"] == profile]
        if not profile_devices:
            continue
        metrics: dict[str, Decimal] = {}
        for metric in aggregate_metrics:
            values = [
                decimal_value(device[metric])
                for device in profile_devices
                if decimal_value(device[metric]) is not None
            ]
            if values:
                metrics[metric] = sum((value for value in values if value is not None), Decimal(0))
        aggregate_values[profile] = metrics
        profile_aggregates.append(
            {
                "profile": profile,
                "device_count": len(profile_devices),
                **{metric: json_number(value) for metric, value in metrics.items()},
            }
        )

    comparisons = []
    if all(profile in aggregate_values for profile in PROFILES):
        for metric in aggregate_metrics:
            local = aggregate_values["local_nvme"].get(metric)
            ebs = aggregate_values["ebs_gp3"].get(metric)
            if local is not None and ebs is not None:
                comparisons.append(
                    comparison(metric, local, ebs, lower_is_better=False)
                )

    status = "present" if samples else "empty"
    if devices and not any(device["duration_seconds"] for device in devices):
        status = "insufficient_samples"
    return {
        "status": status,
        "files": file_summaries,
        "analysis_source": relative(preferred, root),
        "devices": devices,
        "profile_aggregates": profile_aggregates,
        "comparisons": comparisons,
    }


def parse_metadata(root: Path, warnings: list[str]) -> dict[str, str]:
    path = root / "run-metadata.tsv"
    if not path.is_file():
        return {}
    metadata: dict[str, str] = {}
    try:
        for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
            fields = line.split("\t", 1)
            if len(fields) != 2 or not fields[0]:
                warnings.append(f"run-metadata.tsv: line {line_number}: invalid metadata row skipped")
                continue
            metadata[fields[0]] = fields[1]
    except (OSError, UnicodeError) as exc:
        warnings.append(f"run-metadata.tsv: could not read metadata: {exc}")
    return dict(sorted(metadata.items()))


def markdown_value(value: object, suffix: str = "") -> str:
    if value is None:
        return "missing"
    return f"{value}{suffix}"


def comparison_table(comparisons: Iterable[dict[str, Any]], context_keys: tuple[str, ...]) -> list[str]:
    rows = list(comparisons)
    if not rows:
        return ["No comparable `local_nvme` and `ebs_gp3` measurements were present.", ""]
    headers = [*context_keys, "Metric", "Local NVMe", "EBS gp3", "EBS vs NVMe"]
    lines = [
        "| " + " | ".join(headers) + " |",
        "|" + "|".join("---" for _ in headers) + "|",
    ]
    for row in rows:
        context = [str(row.get(key, "")) for key in context_keys]
        delta = row.get("candidate_vs_baseline_pct")
        lines.append(
            "| "
            + " | ".join(
                [
                    *context,
                    str(row["metric"]),
                    markdown_value(row.get("baseline")),
                    markdown_value(row.get("candidate")),
                    markdown_value(delta, "%"),
                ]
            )
            + " |"
        )
    lines.append("")
    return lines


def render_markdown(summary: dict[str, Any]) -> str:
    sections = summary["sections"]
    lines = [
        "# Storage Selection Benchmark Summary",
        "",
        f"- Result directory: `{summary['result_directory']}`",
        f"- Analyzer schema: `{summary['schema_version']}`",
        "- Percentage formula: `(EBS gp3 - local NVMe) / local NVMe * 100`",
        "- Positive percentages mean EBS produced a larger measured value.",
        "",
        "## Completeness",
        "",
    ]
    for name in ("clickbench", "qps", "load", "merge", "disk_counters"):
        lines.append(f"- `{name}`: **{sections[name]['status']}**")
    if summary["missing_sections"]:
        lines.append(f"- Missing sections: {', '.join(summary['missing_sections'])}")
    else:
        lines.append("- Missing sections: none")
    lines.append("")

    lines.extend(["## ClickBench", ""])
    clickbench = sections["clickbench"]
    if clickbench["status"] == "missing":
        lines.extend(["Missing: no nested `clickbench.csv` files were found.", ""])
    elif not clickbench["groups"]:
        lines.extend(["Present but empty: no valid ClickBench rows were parsed.", ""])
    else:
        lines.extend(
            [
                "| Dataset | Profile | Mode | Queries | Total best (s) | Mean (s) | Median (s) | P95 (s) |",
                "|---|---|---|---:|---:|---:|---:|---:|",
            ]
        )
        for group in clickbench["groups"]:
            lines.append(
                "| {dataset} | {profile} | {mode} | {query_count} | {total} | {mean} | {median} | {p95} |".format(
                    dataset=group["dataset"],
                    profile=group["profile"],
                    mode=group["mode"],
                    query_count=group["query_count"],
                    total=markdown_value(group["total_best_seconds"]),
                    mean=markdown_value(group["mean_best_seconds"]),
                    median=markdown_value(group["median_best_seconds"]),
                    p95=markdown_value(group["p95_best_seconds"]),
                )
            )
        lines.append("")
        lines.extend(comparison_table(clickbench["comparisons"], ("dataset", "mode")))

    lines.extend(["## QPS And Latency", ""])
    qps = sections["qps"]
    if qps["status"] == "missing":
        lines.extend(["Missing: no recognized QPS logs were found.", ""])
    elif not qps["runs"]:
        lines.extend(["Present but empty: no QPS logs were parsed.", ""])
    else:
        lines.extend(
            [
                "| Workload | Concurrency | Profile | QPS | RPS | MiB/s | P50 (s) | P95 (s) | P99 (s) | Errors |",
                "|---|---:|---|---:|---:|---:|---:|---:|---:|---:|",
            ]
        )
        for run in qps["runs"]:
            latency = run.get("latency_seconds", {})
            lines.append(
                "| {workload} | {concurrency} | {profile} | {qps} | {rps} | {mib} | {p50} | {p95} | {p99} | {errors} |".format(
                    workload=run["workload"],
                    concurrency=markdown_value(run["concurrency"]),
                    profile=run["profile"],
                    qps=markdown_value(run.get("qps")),
                    rps=markdown_value(run.get("rps")),
                    mib=markdown_value(run.get("mib_per_second")),
                    p50=markdown_value(latency.get("p50")),
                    p95=markdown_value(latency.get("p95")),
                    p99=markdown_value(latency.get("p99")),
                    errors=markdown_value(run.get("errors")),
                )
            )
        lines.append("")
        lines.extend(comparison_table(qps["comparisons"], ("workload", "concurrency")))

    lines.extend(["## Load", ""])
    load = sections["load"]
    if load["status"] == "missing":
        lines.extend(["Missing: no nested `load-seconds.csv` files were found.", ""])
    elif not load["groups"]:
        lines.extend(["Present but empty: no valid load timing rows were parsed.", ""])
    else:
        lines.extend(
            [
                "| Dataset | Profile | Samples | Total insert (s) | Mean insert (s) | Total ready (s) | Mean ready (s) |",
                "|---|---|---:|---:|---:|---:|---:|",
            ]
        )
        for group in load["groups"]:
            lines.append(
                "| {dataset} | {profile} | {samples} | {total_insert} | {mean_insert} | {total_ready} | {mean_ready} |".format(
                    dataset=group["dataset"],
                    profile=group["profile"],
                    samples=group["samples"],
                    total_insert=markdown_value(group["total_insert_seconds"]),
                    mean_insert=markdown_value(group["mean_insert_seconds"]),
                    total_ready=markdown_value(group["total_replicas_ready_seconds"]),
                    mean_ready=markdown_value(group["mean_replicas_ready_seconds"]),
                )
            )
        lines.append("")
        lines.extend(comparison_table(load["comparisons"], ("dataset",)))

    lines.extend(["## FINAL Merge", ""])
    merge = sections["merge"]
    if merge["status"] == "missing":
        lines.extend(["Missing: `merge-final.csv` was not found.", ""])
    elif not merge["runs"]:
        lines.extend(["Present but empty: no valid merge timing rows were parsed.", ""])
    else:
        lines.extend(
            [
                "| Profile | OPTIMIZE FINAL (s) |",
                "|---|---:|",
            ]
        )
        for run in merge["runs"]:
            lines.append(f"| {run['profile']} | {markdown_value(run['optimize_seconds'])} |")
        lines.append("")
        lines.extend(comparison_table(merge["comparisons"], ()))

    lines.extend(["## Disk Counters", ""])
    disk = sections["disk_counters"]
    if disk["status"] == "missing":
        lines.extend(["Missing: no `disk-counters*.tsv` logs were found.", ""])
    elif not disk["devices"]:
        lines.extend(["Present but empty: no valid disk counter samples were parsed.", ""])
    elif disk["status"] == "insufficient_samples":
        lines.extend(
            [
                "Insufficient samples: disk counters were parsed, but no device had two valid samples.",
                "",
            ]
        )
    else:
        lines.append(f"Analysis source: `{disk['analysis_source']}`")
        lines.extend(
            [
                "",
                "| Node | Device | Profile | Duration (s) | Avg read MiB/s | Avg write MiB/s | Avg read IOPS | Avg write IOPS | Peak busy |",
                "|---|---|---|---:|---:|---:|---:|---:|---:|",
            ]
        )
        for device in disk["devices"]:
            lines.append(
                "| {node} | {device} | {profile} | {duration} | {read_mib} | {write_mib} | {read_iops} | {write_iops} | {busy} |".format(
                    node=device["node"],
                    device=device["device"],
                    profile=markdown_value(device["profile"]),
                    duration=markdown_value(device["duration_seconds"]),
                    read_mib=markdown_value(device["average_read_mib_per_second"]),
                    write_mib=markdown_value(device["average_write_mib_per_second"]),
                    read_iops=markdown_value(device["average_read_iops"]),
                    write_iops=markdown_value(device["average_write_iops"]),
                    busy=markdown_value(device["peak_interval_busy_pct"], "%"),
                )
            )
        lines.append("")
        lines.extend(comparison_table(disk["comparisons"], ()))

    lines.extend(["## Warnings", ""])
    if summary["warnings"]:
        lines.extend(f"- {warning}" for warning in summary["warnings"])
    else:
        lines.append("- None")
    lines.append("")
    return "\n".join(lines)


def analyze(root: Path) -> dict[str, Any]:
    warnings: list[str] = []
    sections = {
        "clickbench": analyze_clickbench(root, warnings),
        "qps": analyze_qps(root, warnings),
        "load": analyze_load(root, warnings),
        "merge": analyze_merge(root, warnings),
        "disk_counters": analyze_disk_counters(root, warnings),
    }
    missing = [name for name, section in sections.items() if section["status"] == "missing"]
    return {
        "schema_version": SCHEMA_VERSION,
        "result_directory": root.name,
        "metadata": parse_metadata(root, warnings),
        "missing_sections": missing,
        "sections": sections,
        "warnings": sorted(set(warnings)),
    }


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Parse one results/storage-selection/<timestamp> directory and write "
            "deterministic summary.json and summary.md files into it."
        )
    )
    parser.add_argument(
        "result_directory",
        type=Path,
        help="path to one storage-selection benchmark timestamp directory",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    root = args.result_directory.expanduser()
    if not root.is_dir():
        print(f"error: result directory does not exist or is not a directory: {root}", file=sys.stderr)
        return 2

    summary = analyze(root)
    json_text = json.dumps(summary, indent=2, sort_keys=True, ensure_ascii=True) + "\n"
    markdown_text = render_markdown(summary)
    try:
        (root / "summary.json").write_text(json_text, encoding="utf-8", newline="\n")
        (root / "summary.md").write_text(markdown_text, encoding="utf-8", newline="\n")
    except OSError as exc:
        print(f"error: could not write summaries: {exc}", file=sys.stderr)
        return 1
    print(f"Wrote {root / 'summary.json'}")
    print(f"Wrote {root / 'summary.md'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
