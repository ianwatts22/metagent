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
    observed_descendant_reported_cpu_percent: float = 0
    observed_descendant_rss_kib: float = 0
    observed_descendant_processes: int = 0


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
            "observed_descendant_reported_cpu_percent",
            "observed_descendant_rss_kib",
            "observed_descendant_processes",
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
                observed_descendant_reported_cpu_percent=optional_number(
                    row, "observed_descendant_reported_cpu_percent", float
                ) or 0,
                observed_descendant_rss_kib=optional_number(
                    row, "observed_descendant_rss_kib", float
                ) or 0,
                observed_descendant_processes=optional_number(
                    row, "observed_descendant_processes", int
                ) or 0,
            )
            for row in reader
        ]
    if not samples:
        raise ValueError(f"no process samples found in {path}")
    if any(later.second <= earlier.second for earlier, later in zip(samples, samples[1:])):
        raise ValueError(f"sample seconds must increase monotonically in {path}")
    return samples


def weighted_nearest_rank(
    values: list[float], weights: list[float], percentile: float
) -> float:
    ordered = sorted(zip(values, weights), key=lambda pair: pair[0])
    threshold = sum(weights) * percentile / 100
    cumulative = 0.0
    for value, weight in ordered:
        cumulative += weight
        if cumulative >= threshold:
            return value
    return ordered[-1][0]


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


def active_bursts(
    samples: list[ProcessSample], threshold: float
) -> list[tuple[float, int]]:
    bursts: list[tuple[float, int]] = []
    current = 0.0
    sample_count = 0
    for sample, interval in zip(samples, sample_intervals(samples)):
        if sample.cpu_percent >= threshold:
            current += interval
            sample_count += 1
        elif current > 0:
            bursts.append((current, sample_count))
            current = 0.0
            sample_count = 0
    if current > 0:
        bursts.append((current, sample_count))
    return bursts


def summarize(
    samples: list[ProcessSample],
    *,
    channel: str,
    pid: int,
    active_cpu_threshold: float,
    processed_usage_bytes: int | None,
    high_cpu_threshold: float = 20.0,
    provenance: dict[str, object] | None = None,
) -> dict[str, object]:
    cpu = [sample.cpu_percent for sample in samples]
    rss_mib = [sample.rss_kib / 1024 for sample in samples]
    descendant_reported_cpu = [
        sample.observed_descendant_reported_cpu_percent for sample in samples
    ]
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
    high_cpu_bursts = active_bursts(samples, high_cpu_threshold)
    result: dict[str, object] = {
        "schema_version": 2,
        "channel": channel,
        "pid": pid,
        "samples": len(samples),
        "measurement": {
            "actual_elapsed_seconds": total_seconds,
            "sample_interval_clock": "monotonic",
        },
        "provenance": provenance or {},
        "cpu": {
            "average_percent": estimated_cpu_seconds / total_seconds * 100,
            "time_weighted_p50_percent": weighted_nearest_rank(cpu, intervals, 50),
            "time_weighted_p95_percent": weighted_nearest_rank(cpu, intervals, 95),
            "time_weighted_p99_percent": weighted_nearest_rank(cpu, intervals, 99),
            "peak_percent": max(cpu),
            "active_threshold_percent": active_cpu_threshold,
            "active_samples": active_count,
            "active_seconds": active_seconds,
            "active_duty_cycle_percent": active_seconds / total_seconds * 100,
            "longest_active_burst_seconds": longest_active_burst(
                samples, active_cpu_threshold
            ),
            "estimated_cpu_seconds": estimated_cpu_seconds,
            "high_cpu_threshold_percent": high_cpu_threshold,
            "high_cpu_burst_count": len(high_cpu_bursts),
            "high_cpu_bursts_over_one_second": sum(
                duration > 1.0 and sample_count > 1
                for duration, sample_count in high_cpu_bursts
            ),
            "longest_high_cpu_burst_seconds": max(
                (duration for duration, _sample_count in high_cpu_bursts),
                default=0.0,
            ),
        },
        "memory": {
            "time_weighted_average_rss_mib": sum(
                value * interval for value, interval in zip(rss_mib, intervals)
            ) / total_seconds,
            "time_weighted_p95_rss_mib": weighted_nearest_rank(
                rss_mib, intervals, 95
            ),
            "peak_rss_mib": max(rss_mib),
            "rss_growth_mib": rss_mib[-1] - rss_mib[0],
            "rss_trend_mib_per_minute": linear_trend_per_minute(samples),
        },
        "threads": {"peak": max(sample.threads for sample in samples)},
        "observed_descendants": {
            "scope": "point_in_time_samples_only",
            "captures_processes_between_samples": False,
            "sample_average_reported_cpu_percent": sum(descendant_reported_cpu)
            / len(descendant_reported_cpu),
            "sample_p95_reported_cpu_percent": sorted(descendant_reported_cpu)[
                max(math.ceil(0.95 * len(descendant_reported_cpu)) - 1, 0)
            ],
            "sample_peak_reported_cpu_percent": max(descendant_reported_cpu),
            "sample_peak_rss_mib": max(
                sample.observed_descendant_rss_kib for sample in samples
            ) / 1024,
            "sample_peak_processes": max(
                sample.observed_descendant_processes for sample in samples
            ),
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
            "scope": "shared_database_global",
            "global_processed_usage_mib": processed_mib,
            "global_processed_usage_mib_per_second": processed_mib / total_seconds,
        }
        progress_samples = [
            (sample, interval)
            for sample, interval in zip(samples, intervals)
            if (sample.processed_usage_delta_bytes or 0) > 0
        ]
        progress["global_progress_sample_count"] = len(progress_samples)
        progress_seconds = sum(interval for _, interval in progress_samples)
        progress["global_progress_observed_seconds"] = progress_seconds
        progress["global_progress_observed_duty_cycle_percent"] = (
            progress_seconds / total_seconds * 100
        )
        progress["largest_global_progress_interval_mib"] = max(
            (sample.processed_usage_delta_bytes or 0) for sample in samples
        ) / 1_048_576
        result["global_usage_progress"] = progress
    return result


def text_summary(result: dict[str, object]) -> str:
    cpu = result["cpu"]
    memory = result["memory"]
    threads = result["threads"]
    descendants = result["observed_descendants"]
    measurement = result["measurement"]
    provenance = result["provenance"]
    assert isinstance(cpu, dict)
    assert isinstance(memory, dict)
    assert isinstance(threads, dict)
    assert isinstance(descendants, dict)
    assert isinstance(measurement, dict)
    assert isinstance(provenance, dict)
    lines = [
        f"channel: {result['channel']}",
        f"pid: {result['pid']}",
        f"samples: {result['samples']}",
        f"actual_elapsed_seconds: {measurement['actual_elapsed_seconds']:.2f}",
        f"scenario: {provenance.get('scenario', 'unspecified')}",
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
        f"power_snapshot: {provenance.get('power_snapshot', 'unknown')}",
        f"low_power_mode: {provenance.get('low_power_mode', 'unknown')}",
        f"thermal_snapshot: {provenance.get('thermal_snapshot', 'unknown')}",
        f"other_channel: {provenance.get('other_channel', 'unknown')}",
        f"other_channel_running_at_start: {str(provenance.get('other_channel_running_at_start', False)).lower()}",
        f"other_channel_pid_at_start: {provenance.get('other_channel_pid_at_start')}",
        f"average_cpu_percent: {cpu['average_percent']:.2f}",
        f"time_weighted_p50_cpu_percent: {cpu['time_weighted_p50_percent']:.2f}",
        f"time_weighted_p95_cpu_percent: {cpu['time_weighted_p95_percent']:.2f}",
        f"time_weighted_p99_cpu_percent: {cpu['time_weighted_p99_percent']:.2f}",
        f"peak_cpu_percent: {cpu['peak_percent']:.2f}",
        f"active_cpu_threshold_percent: {cpu['active_threshold_percent']:.2f}",
        f"active_cpu_samples: {cpu['active_samples']}",
        f"active_cpu_seconds: {cpu['active_seconds']:.2f}",
        f"active_cpu_duty_cycle_percent: {cpu['active_duty_cycle_percent']:.2f}",
        f"longest_active_cpu_burst_seconds: {cpu['longest_active_burst_seconds']}",
        f"estimated_cpu_seconds: {cpu['estimated_cpu_seconds']:.2f}",
        f"high_cpu_threshold_percent: {cpu['high_cpu_threshold_percent']:.2f}",
        f"high_cpu_burst_count: {cpu['high_cpu_burst_count']}",
        f"high_cpu_bursts_over_one_second: {cpu['high_cpu_bursts_over_one_second']}",
        f"longest_high_cpu_burst_seconds: {cpu['longest_high_cpu_burst_seconds']:.2f}",
        f"time_weighted_average_rss_mib: {memory['time_weighted_average_rss_mib']:.2f}",
        f"time_weighted_p95_rss_mib: {memory['time_weighted_p95_rss_mib']:.2f}",
        f"peak_rss_mib: {memory['peak_rss_mib']:.2f}",
        f"rss_growth_mib: {memory['rss_growth_mib']:.2f}",
        f"rss_trend_mib_per_minute: {memory['rss_trend_mib_per_minute']:.2f}",
        f"peak_threads: {threads['peak']}",
        "observed_descendant_scope: point_in_time_samples_only",
        "observed_descendants_capture_between_samples: false",
        f"sample_average_observed_descendant_reported_cpu_percent: {descendants['sample_average_reported_cpu_percent']:.2f}",
        f"sample_p95_observed_descendant_reported_cpu_percent: {descendants['sample_p95_reported_cpu_percent']:.2f}",
        f"sample_peak_observed_descendant_reported_cpu_percent: {descendants['sample_peak_reported_cpu_percent']:.2f}",
        f"sample_peak_observed_descendant_rss_mib: {descendants['sample_peak_rss_mib']:.2f}",
        f"sample_peak_observed_descendant_processes: {descendants['sample_peak_processes']}",
    ]
    progress = result.get("global_usage_progress")
    if isinstance(progress, dict):
        lines.append("global_usage_progress_scope: shared_database_global")
        lines.append(
            f"global_processed_usage_mib: {progress['global_processed_usage_mib']:.2f}"
        )
        lines.append(
            "global_processed_usage_mib_per_second: "
            f"{progress['global_processed_usage_mib_per_second']:.4f}"
        )
        lines.append(
            f"global_usage_progress_sample_count: {progress['global_progress_sample_count']}"
        )
        lines.append(
            "global_usage_progress_observed_duty_cycle_percent: "
            f"{progress['global_progress_observed_duty_cycle_percent']:.2f}"
        )
        lines.append(
            "largest_global_usage_progress_interval_mib: "
            f"{progress['largest_global_progress_interval_mib']:.2f}"
        )
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("samples", type=Path)
    parser.add_argument("summary", type=Path)
    parser.add_argument("json_output", type=Path)
    parser.add_argument("--channel", choices=("dev", "prod"), required=True)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--active-cpu-threshold", type=float, default=2.0)
    parser.add_argument("--high-cpu-threshold", type=float, default=20.0)
    parser.add_argument("--processed-usage-bytes", type=int)
    parser.add_argument("--scenario", default="unspecified")
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
    parser.add_argument("--power-snapshot", default="unknown")
    parser.add_argument("--low-power-mode", default="unknown")
    parser.add_argument("--thermal-snapshot", default="unknown")
    parser.add_argument("--other-channel", default="unknown")
    parser.add_argument("--other-channel-pid", type=int)
    args = parser.parse_args()

    if args.active_cpu_threshold < 0:
        parser.error("--active-cpu-threshold must be non-negative")
    if args.high_cpu_threshold < 0:
        parser.error("--high-cpu-threshold must be non-negative")
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
            high_cpu_threshold=args.high_cpu_threshold,
            provenance={
                "scenario": args.scenario,
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
                "power_snapshot": args.power_snapshot,
                "low_power_mode": args.low_power_mode,
                "thermal_snapshot": args.thermal_snapshot,
                "other_channel": args.other_channel,
                "other_channel_running_at_start": args.other_channel_pid is not None,
                "other_channel_pid_at_start": args.other_channel_pid,
            },
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
