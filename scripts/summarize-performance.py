#!/usr/bin/env python3
"""Extract XCTest performance metrics and optionally compare a prior run."""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path


MEASUREMENT = re.compile(
    r"Test Case '-\[[^ ]+ (?P<test>[^]]+)\]' measured "
    r"\[(?P<metric>.+), (?P<unit>[^]]+)] average: (?P<average>-?[0-9.]+), "
    r"relative standard deviation: (?P<deviation>-?[0-9.]+)%"
)

# XCTest's non-peak physical-memory metric is a process delta and often moves
# by a few allocator pages around zero. Peak memory remains comparable.
NON_COMPARABLE_METRICS = {"Memory Physical"}
COMPARISON_FLOORS = {
    "Disk Logical Writes": 128.0,
    "Clock Monotonic Time": 0.02,
    "CPU Time": 0.01,
}


def parse_metrics(log_path: Path) -> list[dict[str, object]]:
    metrics: list[dict[str, object]] = []
    for line in log_path.read_text(encoding="utf-8", errors="replace").splitlines():
        match = MEASUREMENT.search(line)
        if not match:
            continue
        metrics.append(
            {
                "test": match.group("test"),
                "metric": match.group("metric"),
                "unit": match.group("unit"),
                "average": float(match.group("average")),
                "relative_standard_deviation_percent": float(match.group("deviation")),
            }
        )
    if not metrics:
        raise ValueError(f"no XCTest performance metrics found in {log_path}")
    return metrics


def metric_key(metric: dict[str, object]) -> tuple[str, str, str]:
    return str(metric["test"]), str(metric["metric"]), str(metric["unit"])


def compare_metrics(
    current: list[dict[str, object]],
    baseline_path: Path,
    max_regression_percent: float,
) -> list[str]:
    baseline = json.loads(baseline_path.read_text(encoding="utf-8"))
    baseline_by_key = {
        metric_key(metric): metric for metric in baseline.get("metrics", [])
    }
    regressions: list[str] = []
    for metric in current:
        if metric["metric"] in NON_COMPARABLE_METRICS:
            continue
        earlier = baseline_by_key.get(metric_key(metric))
        if not earlier:
            continue
        previous = float(earlier["average"])
        latest = float(metric["average"])
        if previous < COMPARISON_FLOORS.get(str(metric["metric"]), 0):
            continue
        change_percent = ((latest - previous) / previous) * 100
        if change_percent > max_regression_percent:
            test, name, unit = metric_key(metric)
            regressions.append(
                f"{test} / {name}: {previous:.3f} -> {latest:.3f} {unit} "
                f"(+{change_percent:.1f}%)"
            )
    return regressions


def print_speed_summary(metrics: list[dict[str, object]]) -> None:
    print("Performance summary (lower is better)")
    for metric in metrics:
        if metric["metric"] not in {"Clock Monotonic Time", "CPU Time", "Memory Peak Physical"}:
            continue
        print(
            f"  {metric['test']}: {metric['metric']} "
            f"{metric['average']:.3f} {metric['unit']}"
        )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("log", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--max-regression-percent", type=float, default=20.0)
    args = parser.parse_args()

    try:
        metrics = parse_metrics(args.log)
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        return 2

    result = {
        "schema_version": 1,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "metrics": metrics,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print_speed_summary(metrics)
    print(f"Machine-readable results: {args.output}")

    if not args.baseline:
        return 0
    if not args.baseline.is_file():
        print(f"performance baseline not found: {args.baseline}", file=sys.stderr)
        return 2
    regressions = compare_metrics(metrics, args.baseline, args.max_regression_percent)
    if not regressions:
        print(
            f"No matched metric regressed by more than "
            f"{args.max_regression_percent:.1f}% against {args.baseline}."
        )
        return 0
    print("Performance regressions:", file=sys.stderr)
    for regression in regressions:
        print(f"  {regression}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
