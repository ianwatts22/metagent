#!/usr/bin/env python3
"""Turn macOS vmmap output into stable, comparable memory metrics."""

from __future__ import annotations

import argparse
import json
import re
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
        "schema_version": 1,
        "physical": {
            "footprint_mib": required_size(text, "Physical footprint"),
            "peak_footprint_mib": required_size(text, "Physical footprint (peak)"),
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
    }


def text_summary(result: dict[str, object]) -> str:
    physical = result["physical"]
    malloc = result["malloc"]
    assert isinstance(physical, dict)
    assert isinstance(malloc, dict)
    return "\n".join(
        [
            f"physical_footprint_mib: {physical['footprint_mib']:.2f}",
            f"peak_physical_footprint_mib: {physical['peak_footprint_mib']:.2f}",
            f"malloc_allocated_mib: {malloc['allocated_mib']:.2f}",
            f"malloc_resident_mib: {malloc['resident_mib']:.2f}",
            f"malloc_dirty_mib: {malloc['dirty_mib']:.2f}",
            f"malloc_swapped_mib: {malloc['swapped_mib']:.2f}",
            f"malloc_fragmentation_mib: {malloc['fragmentation_mib']:.2f}",
            f"malloc_fragmentation_percent: {malloc['fragmentation_percent']}",
            f"malloc_allocation_count: {malloc['allocation_count']}",
            f"malloc_region_count: {malloc['region_count']}",
        ]
    ) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("vmmap_summary", type=Path)
    parser.add_argument("--json-output", type=Path)
    args = parser.parse_args()

    try:
        result = parse_vmmap_summary(args.vmmap_summary.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        return 2

    if args.json_output is not None:
        args.json_output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(text_summary(result), end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
