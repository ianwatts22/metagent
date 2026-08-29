#!/usr/bin/env python3
"""Turn one or more macOS vmmap snapshots into comparable memory metrics."""

from __future__ import annotations

import argparse
import json
import re
import statistics
import sys
from pathlib import Path


SIZE_PATTERN = r"([0-9]+(?:\.[0-9]+)?[KMG]?)"


def size_mib(value: str) -> float:
    match = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)([KMG]?)", value)
    if match is None:
        raise ValueError(f"invalid vmmap size: {value}")
    number = float(match.group(1))
    return number * {"": 1 / 1_048_576, "K": 1 / 1024, "M": 1, "G": 1024}[match.group(2)]


def required_size(text: str, label: str) -> float:
    match = re.search(rf"^{re.escape(label)}:\s+{SIZE_PATTERN}\s*$", text, re.MULTILINE)
    if match is None:
        raise ValueError(f"vmmap output is missing {label.lower()}")
    return size_mib(match.group(1))


def header_value(text: str, label: str) -> str | None:
    match = re.search(rf"^{re.escape(label)}:\s+(.+?)\s*$", text, re.MULTILINE)
    return match.group(1) if match is not None else None


def parse_vmmap_summary(text: str) -> dict[str, object]:
    try:
        malloc_section = text.split("MALLOC ZONE", maxsplit=1)[1]
    except IndexError as error:
        raise ValueError("vmmap output is missing the malloc zone table") from error

    total_match = re.search(
        rf"^TOTAL\s+"
        rf"{SIZE_PATTERN}\s+"  # virtual
        rf"{SIZE_PATTERN}\s+"  # resident
        rf"{SIZE_PATTERN}\s+"  # dirty
        rf"{SIZE_PATTERN}\s+"  # swapped
        rf"([0-9]+)\s+"        # allocation count
        rf"{SIZE_PATTERN}\s+"  # allocated
        rf"{SIZE_PATTERN}\s+"  # fragmentation
        rf"([0-9]+)%\s+"       # fragmentation percent
        rf"([0-9]+)\s*$",      # region count
        malloc_section,
        re.MULTILINE,
    )
    if total_match is None:
        raise ValueError("vmmap output is missing the malloc zone total")

    return {
        "captured_at": header_value(text, "Date/Time"),
        "physical": {
            "footprint_mib": required_size(text, "Physical footprint"),
            "process_lifetime_peak_footprint_mib": required_size(
                text, "Physical footprint (peak)"
            ),
        },
        "malloc": {
            "virtual_mib": size_mib(total_match.group(1)),
            "resident_mib": size_mib(total_match.group(2)),
            "dirty_mib": size_mib(total_match.group(3)),
            "swapped_mib": size_mib(total_match.group(4)),
            "allocation_count": int(total_match.group(5)),
            "allocated_mib": size_mib(total_match.group(6)),
            "fragmentation_mib": size_mib(total_match.group(7)),
            "fragmentation_percent": int(total_match.group(8)),
            "region_count": int(total_match.group(9)),
        },
        "process": {
            "name": header_value(text, "Process"),
            "identifier": header_value(text, "Identifier"),
            "version": header_value(text, "Version"),
            "launched_at": header_value(text, "Launch Time"),
            "os_version": header_value(text, "OS Version"),
        },
    }


def metric_range(values: list[float | int]) -> dict[str, float | int]:
    return {"min": min(values), "max": max(values)}


def summarize(
    samples: list[dict[str, object]],
    *,
    channel: str | None,
    pid: int | None,
    scenario: str | None,
    executable_path: str | None,
    executable_sha256: str | None,
    settle_seconds: int,
    sample_interval_seconds: int,
) -> dict[str, object]:
    if not samples:
        raise ValueError("at least one vmmap sample is required")
    if len(samples) % 2 == 0:
        raise ValueError("an odd number of vmmap samples is required")

    physical_samples = [sample["physical"] for sample in samples]
    malloc_samples = [sample["malloc"] for sample in samples]
    assert all(isinstance(sample, dict) for sample in physical_samples)
    assert all(isinstance(sample, dict) for sample in malloc_samples)

    def physical_values(key: str) -> list[float]:
        return [float(sample[key]) for sample in physical_samples]  # type: ignore[index]

    def malloc_values(key: str) -> list[float | int]:
        return [sample[key] for sample in malloc_samples]  # type: ignore[index]

    first_process = samples[0]["process"]
    assert isinstance(first_process, dict)
    for sample in samples[1:]:
        process = sample["process"]
        assert isinstance(process, dict)
        if process != first_process:
            raise ValueError("vmmap samples describe different app processes or builds")
    physical_footprints = physical_values("footprint_mib")
    lifetime_peaks = physical_values("process_lifetime_peak_footprint_mib")
    malloc_metric_names = (
        "virtual_mib",
        "resident_mib",
        "dirty_mib",
        "swapped_mib",
        "allocation_count",
        "allocated_mib",
        "fragmentation_mib",
        "fragmentation_percent",
        "region_count",
    )
    malloc_summary = {
        key: statistics.median(malloc_values(key)) for key in malloc_metric_names
    }
    malloc_summary["ranges"] = {
        key: metric_range(malloc_values(key)) for key in malloc_metric_names
    }

    return {
        "schema_version": 2,
        "metadata": {
            "channel": channel,
            "pid": pid,
            "scenario": scenario,
            "executable_path": executable_path,
            "executable_sha256": executable_sha256,
            "process_name": first_process.get("name"),
            "process_identifier": first_process.get("identifier"),
            "app_version": first_process.get("version"),
            "os_version": first_process.get("os_version"),
            "process_launched_at": first_process.get("launched_at"),
            "capture_started_at": samples[0].get("captured_at"),
            "capture_finished_at": samples[-1].get("captured_at"),
            "settle_seconds": settle_seconds,
            "sample_count": len(samples),
            "sample_interval_seconds": sample_interval_seconds,
        },
        "physical": {
            "footprint_mib": statistics.median(physical_footprints),
            "footprint_range_mib": metric_range(physical_footprints),
            # vmmap reports this since launch. It is intentionally outside the
            # snapshot median and must not be treated as a per-scenario peak.
            "process_lifetime_peak_footprint_mib": max(lifetime_peaks),
        },
        "malloc": malloc_summary,
        "samples": samples,
    }


def text_summary(result: dict[str, object]) -> str:
    metadata = result["metadata"]
    physical = result["physical"]
    malloc = result["malloc"]
    assert isinstance(metadata, dict)
    assert isinstance(physical, dict)
    assert isinstance(malloc, dict)
    physical_range = physical["footprint_range_mib"]
    assert isinstance(physical_range, dict)
    lines = [
        f"channel: {metadata['channel'] or 'unspecified'}",
        f"pid: {metadata['pid'] if metadata['pid'] is not None else 'unspecified'}",
        f"scenario: {metadata['scenario'] or 'unspecified'}",
        f"executable_path: {metadata['executable_path'] or 'unspecified'}",
        f"executable_sha256: {metadata['executable_sha256'] or 'unknown'}",
        f"app_version: {metadata['app_version'] or 'unknown'}",
        f"os_version: {metadata['os_version'] or 'unknown'}",
        f"process_launched_at: {metadata['process_launched_at'] or 'unknown'}",
        f"capture_started_at: {metadata['capture_started_at'] or 'unknown'}",
        f"capture_finished_at: {metadata['capture_finished_at'] or 'unknown'}",
        f"settle_seconds: {metadata['settle_seconds']}",
        f"sample_count: {metadata['sample_count']}",
        f"sample_interval_seconds: {metadata['sample_interval_seconds']}",
        f"median_physical_footprint_mib: {physical['footprint_mib']:.2f}",
        "physical_footprint_range_mib: "
        f"{physical_range['min']:.2f}...{physical_range['max']:.2f}",
        "process_lifetime_peak_physical_footprint_mib: "
        f"{physical['process_lifetime_peak_footprint_mib']:.2f}",
        f"median_malloc_allocated_mib: {malloc['allocated_mib']:.2f}",
        f"median_malloc_resident_mib: {malloc['resident_mib']:.2f}",
        f"median_malloc_dirty_mib: {malloc['dirty_mib']:.2f}",
        f"median_malloc_swapped_mib: {malloc['swapped_mib']:.2f}",
        f"median_malloc_fragmentation_mib: {malloc['fragmentation_mib']:.2f}",
        f"median_malloc_fragmentation_percent: {malloc['fragmentation_percent']}",
        f"median_malloc_allocation_count: {malloc['allocation_count']}",
        f"median_malloc_region_count: {malloc['region_count']}",
    ]
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("vmmap_summaries", type=Path, nargs="+")
    parser.add_argument("--json-output", type=Path)
    parser.add_argument("--channel", choices=("dev", "prod"))
    parser.add_argument("--pid", type=int)
    parser.add_argument("--scenario")
    parser.add_argument("--executable-path")
    parser.add_argument("--executable-sha256")
    parser.add_argument("--settle-seconds", type=int, default=0)
    parser.add_argument("--sample-interval-seconds", type=int, default=0)
    args = parser.parse_args()

    try:
        parsed_samples = [
            parse_vmmap_summary(path.read_text(encoding="utf-8"))
            for path in args.vmmap_summaries
        ]
        result = summarize(
            parsed_samples,
            channel=args.channel,
            pid=args.pid,
            scenario=args.scenario,
            executable_path=args.executable_path,
            executable_sha256=args.executable_sha256,
            settle_seconds=args.settle_seconds,
            sample_interval_seconds=args.sample_interval_seconds,
        )
        if args.json_output is not None:
            args.json_output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    except (OSError, TypeError, ValueError) as error:
        print(error, file=sys.stderr)
        return 2

    print(text_summary(result), end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
