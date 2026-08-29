#!/usr/bin/env python3
"""Validate and summarize Accessibility-driven app interaction samples."""

from __future__ import annotations

import argparse
import json
import math
import statistics
import sys
from collections import defaultdict
from pathlib import Path


def percentile(values: list[float], quantile: float) -> float:
    if not values:
        raise ValueError("cannot calculate a percentile without samples")
    ordered = sorted(values)
    return ordered[max(math.ceil(quantile * len(ordered)) - 1, 0)]


def read_raw(path: Path) -> dict[str, object]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict) or value.get("schema_version") != 1:
        raise ValueError(f"{path} is not a supported interaction measurement")
    samples = value.get("samples")
    if not isinstance(samples, list) or not samples:
        raise ValueError(f"{path} contains no interaction samples")
    for sample in samples:
        if not isinstance(sample, dict):
            raise ValueError(f"{path} contains a non-object interaction sample")
        metric = sample.get("metric")
        measured = sample.get("value_ms")
        if not isinstance(metric, str) or not metric:
            raise ValueError(f"{path} contains a sample without a metric")
        if not isinstance(measured, (int, float)) or measured < 0:
            raise ValueError(f"{path} contains an invalid interaction duration")
    return value


def summarize(
    raw: dict[str, object], provenance: dict[str, object]
) -> dict[str, object]:
    samples = raw["samples"]
    assert isinstance(samples, list)
    by_metric: dict[str, list[dict[str, object]]] = defaultdict(list)
    for sample in samples:
        assert isinstance(sample, dict)
        by_metric[str(sample["metric"])].append(sample)

    metrics: dict[str, object] = {}
    for metric, metric_samples in sorted(by_metric.items()):
        values = [float(sample["value_ms"]) for sample in metric_samples]
        presentations = [
            bool(sample.get("presentation_observed", False))
            for sample in metric_samples
        ]
        by_interaction: dict[str, list[float]] = defaultdict(list)
        for sample in metric_samples:
            by_interaction[str(sample.get("interaction", "unknown"))].append(
                float(sample["value_ms"])
            )
        metrics[metric] = {
            "unit": "ms",
            "samples": len(values),
            "minimum": min(values),
            "median": statistics.median(values),
            "p95": percentile(values, 0.95),
            "maximum": max(values),
            "all_presentations_observed": all(presentations),
            "interactions": {
                interaction: {
                    "samples": len(interaction_values),
                    "median": statistics.median(interaction_values),
                    "p95": percentile(interaction_values, 0.95),
                    "maximum": max(interaction_values),
                }
                for interaction, interaction_values in sorted(by_interaction.items())
            },
        }

    return {
        "schema_version": 1,
        "scenario": raw.get("scenario"),
        "automation": raw.get("automation"),
        "process_name": raw.get("process_name"),
        "navigation_button_count": raw.get("navigation_button_count"),
        "metrics": metrics,
        "samples": samples,
        "coverage_gaps": raw.get("coverage_gaps", []),
        "provenance": provenance,
    }


def text_summary(result: dict[str, object]) -> str:
    provenance = result["provenance"]
    metrics = result["metrics"]
    assert isinstance(provenance, dict)
    assert isinstance(metrics, dict)
    lines = [
        f"scenario: {result['scenario']}",
        f"automation: {result['automation']}",
        f"process_name: {result['process_name']}",
        f"repo_commit: {provenance.get('repo_commit', 'unknown')}",
        f"build_commit: {provenance.get('build_commit', 'unknown')}",
        f"app_version: {provenance.get('app_version', 'unknown')}",
        f"app_build: {provenance.get('app_build', 'unknown')}",
        f"executable_path: {provenance.get('executable_path', 'unknown')}",
        f"executable_sha256: {provenance.get('executable_sha256', 'unknown')}",
        f"os: {provenance.get('os_version', 'unknown')} ({provenance.get('os_build', 'unknown')})",
        f"hardware_model: {provenance.get('hardware_model', 'unknown')}",
        f"cpu_model: {provenance.get('cpu_model', 'unknown')}",
        f"power_source: {provenance.get('power_source', 'unknown')}",
        f"low_power_mode: {provenance.get('low_power_mode', 'unknown')}",
    ]
    for name, metric in metrics.items():
        assert isinstance(metric, dict)
        lines.extend(
            [
                f"{name}_samples: {metric['samples']}",
                f"{name}_median_ms: {metric['median']:.2f}",
                f"{name}_p95_ms: {metric['p95']:.2f}",
                f"{name}_max_ms: {metric['maximum']:.2f}",
                f"{name}_all_presentations_observed: {str(metric['all_presentations_observed']).lower()}",
            ]
        )
    gaps = result.get("coverage_gaps", [])
    if isinstance(gaps, list):
        for gap in gaps:
            lines.append(f"coverage_gap: {gap}")
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("raw", type=Path)
    parser.add_argument("text_output", type=Path)
    parser.add_argument("json_output", type=Path)
    parser.add_argument("--repo-commit", default="unknown")
    parser.add_argument("--build-commit", default="unknown")
    parser.add_argument("--app-version", default="unknown")
    parser.add_argument("--app-build", default="unknown")
    parser.add_argument("--executable-path", default="unknown")
    parser.add_argument("--executable-sha256", default="unknown")
    parser.add_argument("--os-version", default="unknown")
    parser.add_argument("--os-build", default="unknown")
    parser.add_argument("--hardware-model", default="unknown")
    parser.add_argument("--cpu-model", default="unknown")
    parser.add_argument("--power-source", default="unknown")
    parser.add_argument("--low-power-mode", default="unknown")
    args = parser.parse_args()

    try:
        result = summarize(
            read_raw(args.raw),
            {
                "repo_commit": args.repo_commit,
                "build_commit": args.build_commit,
                "app_version": args.app_version,
                "app_build": args.app_build,
                "executable_path": args.executable_path,
                "executable_sha256": args.executable_sha256,
                "os_version": args.os_version,
                "os_build": args.os_build,
                "hardware_model": args.hardware_model,
                "cpu_model": args.cpu_model,
                "power_source": args.power_source,
                "low_power_mode": args.low_power_mode,
            },
        )
        args.text_output.write_text(text_summary(result), encoding="utf-8")
        args.json_output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    except (OSError, TypeError, ValueError, json.JSONDecodeError) as error:
        print(error, file=sys.stderr)
        return 2
    print(args.text_output.read_text(encoding="utf-8"), end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
