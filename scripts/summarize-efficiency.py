#!/usr/bin/env python3
"""Summarize a running-app CPU/RSS/thread sample without hiding burstiness."""

from __future__ import annotations

import argparse
import csv
import json
import math
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class ProcessSample:
    second: float
    cpu_percent: float
    rss_kib: float
    threads: int
    processed_usage_bytes: int | None = None
    processed_usage_delta_bytes: int | None = None
    child_cpu_percent: float = 0
    child_rss_kib: float = 0
    child_processes: int = 0


def optional_number(row: dict[str, str], key: str, cast: type[int] | type[float]):
    value = row.get(key, "")
    return cast(value) if value else None


def read_samples(path: Path) -> list[ProcessSample]:
    with path.open(newline="", encoding="utf-8") as source:
        reader = csv.DictReader(source)
        required = {"second", "cpu_percent", "rss_kib", "threads"}
        optional = {
            "processed_usage_bytes",
            "processed_usage_delta_bytes",
            "child_cpu_percent",
            "child_rss_kib",
            "child_processes",
        }
        fields = set(reader.fieldnames or [])
        if not required.issubset(fields) or not fields.issubset(required | optional):
            raise ValueError(
                f"{path} must contain {', '.join(sorted(required))} and only supported optional columns"
            )
        samples = [
            ProcessSample(
                second=float(row["second"]),
                cpu_percent=float(row["cpu_percent"]),
                rss_kib=float(row["rss_kib"]),
                threads=int(row["threads"]),
                processed_usage_bytes=optional_number(
                    row, "processed_usage_bytes", int
                ),
                processed_usage_delta_bytes=optional_number(
                    row, "processed_usage_delta_bytes", int
                ),
                child_cpu_percent=optional_number(
                    row, "child_cpu_percent", float
                ) or 0,
                child_rss_kib=optional_number(row, "child_rss_kib", float) or 0,
                child_processes=optional_number(row, "child_processes", int) or 0,
            )
            for row in reader
        ]
    if not samples:
        raise ValueError(f"no process samples found in {path}")
    if any(later.second <= earlier.second for earlier, later in zip(samples, samples[1:])):
        raise ValueError(f"sample seconds must increase monotonically in {path}")
    return samples


def nearest_rank(values: list[float], percentile: float) -> float:
    ordered = sorted(values)
    index = max(math.ceil(percentile / 100 * len(ordered)) - 1, 0)
    return ordered[index]


def linear_trend_per_minute(samples: list[ProcessSample]) -> float:
    if len(samples) < 2:
        return 0.0
    mean_second = sum(sample.second for sample in samples) / len(samples)
    mean_rss = sum(sample.rss_kib for sample in samples) / len(samples)
    denominator = sum((sample.second - mean_second) ** 2 for sample in samples)
    if denominator == 0:
        return 0.0
    kib_per_second = sum(
        (sample.second - mean_second) * (sample.rss_kib - mean_rss)
        for sample in samples
    ) / denominator
    return kib_per_second * 60 / 1024


def sample_intervals(samples: list[ProcessSample]) -> list[float]:
    previous = 0.0
    intervals: list[float] = []
    for sample in samples:
        intervals.append(sample.second - previous)
        previous = sample.second
    return intervals


def longest_active_burst(samples: list[ProcessSample], threshold: float) -> float:
    longest = 0.0
    current = 0.0
    for sample, interval in zip(samples, sample_intervals(samples)):
        if sample.cpu_percent >= threshold:
            current += interval
            longest = max(longest, current)
        else:
            current = 0.0
    return longest


def summarize(
    samples: list[ProcessSample],
    *,
    channel: str,
    pid: int,
    active_cpu_threshold: float,
    processed_usage_bytes: int | None,
) -> dict[str, object]:
    cpu = [sample.cpu_percent for sample in samples]
    rss_mib = [sample.rss_kib / 1024 for sample in samples]
    child_cpu = [sample.child_cpu_percent for sample in samples]
    intervals = sample_intervals(samples)
    total_seconds = sum(intervals)
    active_count = sum(value >= active_cpu_threshold for value in cpu)
    active_seconds = sum(
        interval
        for value, interval in zip(cpu, intervals)
        if value >= active_cpu_threshold
    )
    estimated_cpu_seconds = sum(
        value * interval for value, interval in zip(cpu, intervals)
    ) / 100
    result: dict[str, object] = {
        "schema_version": 1,
        "channel": channel,
        "pid": pid,
        "samples": len(samples),
        "cpu": {
            "average_percent": estimated_cpu_seconds / total_seconds * 100,
            "p50_percent": nearest_rank(cpu, 50),
            "p95_percent": nearest_rank(cpu, 95),
            "p99_percent": nearest_rank(cpu, 99),
            "peak_percent": max(cpu),
            "active_threshold_percent": active_cpu_threshold,
            "active_samples": active_count,
            "active_seconds": active_seconds,
            "active_duty_cycle_percent": active_seconds / total_seconds * 100,
            "longest_active_burst_seconds": longest_active_burst(
                samples, active_cpu_threshold
            ),
            "estimated_cpu_seconds": estimated_cpu_seconds,
        },
        "memory": {
            "average_rss_mib": sum(rss_mib) / len(rss_mib),
            "p95_rss_mib": nearest_rank(rss_mib, 95),
            "peak_rss_mib": max(rss_mib),
            "rss_growth_mib": rss_mib[-1] - rss_mib[0],
            "rss_trend_mib_per_minute": linear_trend_per_minute(samples),
        },
        "threads": {"peak": max(sample.threads for sample in samples)},
        "children": {
            "average_reported_cpu_percent": sum(child_cpu) / len(child_cpu),
            "p95_reported_cpu_percent": nearest_rank(child_cpu, 95),
            "peak_reported_cpu_percent": max(child_cpu),
            "peak_rss_mib": max(sample.child_rss_kib for sample in samples) / 1024,
            "peak_processes": max(sample.child_processes for sample in samples),
        },
    }
    sampled_usage_bytes = sum(
        sample.processed_usage_delta_bytes or 0 for sample in samples
    )
    if processed_usage_bytes is None and any(
        sample.processed_usage_delta_bytes is not None for sample in samples
    ):
        processed_usage_bytes = sampled_usage_bytes
    if processed_usage_bytes is not None:
        processed_mib = processed_usage_bytes / 1_048_576
        progress: dict[str, object] = {
            "processed_usage_mib": processed_mib,
            "estimated_cpu_seconds": estimated_cpu_seconds,
            "scope": "shared_database",
        }
        if processed_mib > 0:
            progress["cpu_seconds_per_processed_mib"] = (
                estimated_cpu_seconds / processed_mib
            )
        progress_samples = [
            (sample, interval)
            for sample, interval in zip(samples, intervals)
            if (sample.processed_usage_delta_bytes or 0) > 0
        ]
        progress["active_samples"] = len(progress_samples)
        progress_seconds = sum(interval for _, interval in progress_samples)
        progress["active_seconds"] = progress_seconds
        progress["active_duty_cycle_percent"] = progress_seconds / total_seconds * 100
        progress["largest_sample_mib"] = max(
            (sample.processed_usage_delta_bytes or 0) for sample in samples
        ) / 1_048_576
        progress["selected_app_cpu_seconds_in_progress_intervals"] = sum(
            sample.cpu_percent * interval for sample, interval in progress_samples
        ) / 100
        result["usage_progress"] = progress
    return result


def text_summary(result: dict[str, object]) -> str:
    cpu = result["cpu"]
    memory = result["memory"]
    threads = result["threads"]
    children = result["children"]
    assert isinstance(cpu, dict)
    assert isinstance(memory, dict)
    assert isinstance(threads, dict)
    assert isinstance(children, dict)
    lines = [
        f"channel: {result['channel']}",
        f"pid: {result['pid']}",
        f"samples: {result['samples']}",
        f"average_cpu_percent: {cpu['average_percent']:.2f}",
        f"p50_cpu_percent: {cpu['p50_percent']:.2f}",
        f"p95_cpu_percent: {cpu['p95_percent']:.2f}",
        f"p99_cpu_percent: {cpu['p99_percent']:.2f}",
        f"peak_cpu_percent: {cpu['peak_percent']:.2f}",
        f"active_cpu_threshold_percent: {cpu['active_threshold_percent']:.2f}",
        f"active_cpu_samples: {cpu['active_samples']}",
        f"active_cpu_seconds: {cpu['active_seconds']:.2f}",
        f"active_cpu_duty_cycle_percent: {cpu['active_duty_cycle_percent']:.2f}",
        f"longest_active_cpu_burst_seconds: {cpu['longest_active_burst_seconds']}",
        f"estimated_cpu_seconds: {cpu['estimated_cpu_seconds']:.2f}",
        f"average_rss_mib: {memory['average_rss_mib']:.2f}",
        f"p95_rss_mib: {memory['p95_rss_mib']:.2f}",
        f"peak_rss_mib: {memory['peak_rss_mib']:.2f}",
        f"rss_growth_mib: {memory['rss_growth_mib']:.2f}",
        f"rss_trend_mib_per_minute: {memory['rss_trend_mib_per_minute']:.2f}",
        f"peak_threads: {threads['peak']}",
        f"average_child_reported_cpu_percent: {children['average_reported_cpu_percent']:.2f}",
        f"p95_child_reported_cpu_percent: {children['p95_reported_cpu_percent']:.2f}",
        f"peak_child_reported_cpu_percent: {children['peak_reported_cpu_percent']:.2f}",
        f"peak_child_rss_mib: {children['peak_rss_mib']:.2f}",
        f"peak_child_processes: {children['peak_processes']}",
    ]
    progress = result.get("usage_progress")
    if isinstance(progress, dict):
        lines.append(f"processed_usage_mib: {progress['processed_usage_mib']:.2f}")
        lines.append(f"usage_progress_samples: {progress['active_samples']}")
        lines.append(
            "usage_progress_duty_cycle_percent: "
            f"{progress['active_duty_cycle_percent']:.2f}"
        )
        lines.append(f"largest_usage_progress_sample_mib: {progress['largest_sample_mib']:.2f}")
        lines.append(
            "selected_app_cpu_seconds_in_global_usage_progress_intervals: "
            f"{progress['selected_app_cpu_seconds_in_progress_intervals']:.2f}"
        )
        if "cpu_seconds_per_processed_mib" in progress:
            lines.append(
                "cpu_seconds_per_processed_mib: "
                f"{progress['cpu_seconds_per_processed_mib']:.4f}"
            )
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("samples", type=Path)
    parser.add_argument("summary", type=Path)
    parser.add_argument("json_output", type=Path)
    parser.add_argument("--channel", choices=("dev", "prod"), required=True)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--active-cpu-threshold", type=float, default=1.0)
    parser.add_argument("--processed-usage-bytes", type=int)
    args = parser.parse_args()

    if args.active_cpu_threshold < 0:
        parser.error("--active-cpu-threshold must be non-negative")
    if args.processed_usage_bytes is not None and args.processed_usage_bytes < 0:
        parser.error("--processed-usage-bytes must be non-negative")
    try:
        samples = read_samples(args.samples)
        result = summarize(
            samples,
            channel=args.channel,
            pid=args.pid,
            active_cpu_threshold=args.active_cpu_threshold,
            processed_usage_bytes=args.processed_usage_bytes,
        )
    except (OSError, TypeError, ValueError) as error:
        print(error, file=sys.stderr)
        return 2

    args.summary.write_text(text_summary(result), encoding="utf-8")
    args.json_output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(args.summary.read_text(encoding="utf-8"), end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
