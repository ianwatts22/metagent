#!/usr/bin/env python3
"""Compare measured app artifacts with explicit proposed or enforced budgets."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


def read_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return value


def same_memory_identity(before: dict[str, Any], after: dict[str, Any]) -> None:
    before_metadata = before.get("metadata", {})
    after_metadata = after.get("metadata", {})
    if not isinstance(before_metadata, dict) or not isinstance(after_metadata, dict):
        raise ValueError("memory artifacts are missing metadata")
    identity_keys = (
        "channel",
        "pid",
        "executable_path",
        "executable_sha256",
        "app_version",
        "os_version",
        "process_launched_at",
        "settle_seconds",
        "sample_count",
        "sample_interval_seconds",
    )
    mismatches = [
        key for key in identity_keys if before_metadata.get(key) != after_metadata.get(key)
    ]
    if mismatches:
        raise ValueError(
            "memory artifacts describe different app processes or builds: "
            + ", ".join(mismatches)
        )


def observed_metrics(
    *,
    interactions: list[dict[str, Any]] | None,
    efficiency: dict[str, Any] | None,
    memory_before: dict[str, Any] | None,
    memory_after: dict[str, Any] | None,
    allow_scenario_mismatch: bool = False,
) -> tuple[dict[str, float], list[str]]:
    observed: dict[str, float] = {}
    gaps: list[str] = []
    for interaction_artifact in interactions or []:
        interaction_scenario = interaction_artifact.get("scenario")
        if (
            interaction_artifact.get("automation") != "macos_accessibility"
            and not allow_scenario_mismatch
        ):
            raise ValueError(
                "interaction budgets require the macos_accessibility harness"
            )
        metrics = interaction_artifact.get("metrics", {})
        if not isinstance(metrics, dict):
            raise ValueError("interaction artifact is missing metrics")
        launch_metric_map = {
            "warm_launch_to_navigation_ready_ms": "warm_launch_to_navigation_ready_ms",
            "cold_launch_to_navigation_ready_ms": "cold_launch_to_navigation_ready_ms",
            "manual_refresh_to_ready_ms": "manual_refresh_to_ready_p95_ms",
        }
        for source_name, budget_name in launch_metric_map.items():
            metric = metrics.get(source_name)
            if isinstance(metric, dict) and isinstance(metric.get("p95"), (int, float)):
                if (
                    metric.get("all_presentations_observed") is not True
                    and not allow_scenario_mismatch
                ):
                    raise ValueError(
                        f"interaction metric {source_name} did not observe every ready state"
                    )
                expected_scenario = {
                    "warm_launch_to_navigation_ready_ms": "launch-warm",
                    "cold_launch_to_navigation_ready_ms": "launch-cold",
                    "manual_refresh_to_ready_ms": "refresh",
                }[source_name]
                if interaction_scenario == expected_scenario or allow_scenario_mismatch:
                    if budget_name in observed:
                        raise ValueError(
                            f"multiple interaction artifacts provide {budget_name}; "
                            "combine repetitions in one measurement run"
                        )
                    observed[budget_name] = float(metric["p95"])
                else:
                    raise ValueError(
                        f"interaction metric {source_name} requires scenario "
                        f"{expected_scenario}, found {interaction_scenario!r}"
                    )
        selected_state = metrics.get("tab_input_to_selected_state_ms")
        if isinstance(selected_state, dict):
            gaps.append(
                "Tab selected-state latency is diagnostic only; no stable view-specific "
                "presentation sentinel exists, so the input-to-present budget was not evaluated."
            )
        for gap in interaction_artifact.get("coverage_gaps", []):
            if isinstance(gap, str) and gap not in gaps:
                gaps.append(gap)

    if efficiency is not None:
        measurement = efficiency.get("measurement", {})
        if (
            (
                efficiency.get("schema_version") != 2
                or not isinstance(measurement, dict)
                or measurement.get("sample_interval_clock") != "monotonic"
            )
            and not allow_scenario_mismatch
        ):
            raise ValueError(
                "efficiency budgets require schema v2 with monotonic sample intervals"
            )
        provenance = efficiency.get("provenance", {})
        scenario = provenance.get("scenario") if isinstance(provenance, dict) else None
        scenario_words = set(str(scenario or "").lower().replace("_", "-").split("-"))
        required_words = {"settled", "idle", "overview"}
        if not required_words.issubset(scenario_words) and not allow_scenario_mismatch:
            raise ValueError(
                "settled Overview CPU budgets require an efficiency scenario whose label "
                f"contains settled, idle, and overview; found {scenario!r}"
            )
        cpu = efficiency.get("cpu", {})
        if not isinstance(cpu, dict):
            raise ValueError("efficiency artifact is missing CPU metrics")
        high_cpu_threshold = cpu.get("high_cpu_threshold_percent")
        if high_cpu_threshold != 20 and not allow_scenario_mismatch:
            raise ValueError(
                "high-CPU burst budget requires a 20 percent threshold; "
                f"found {high_cpu_threshold!r}"
            )
        mapping = {
            "average_percent": "settled_overview_average_cpu_percent",
            "time_weighted_p95_percent": "settled_overview_p95_cpu_percent",
            "high_cpu_bursts_over_one_second": "settled_overview_high_cpu_bursts_over_1s",
        }
        for source_name, budget_name in mapping.items():
            value = cpu.get(source_name)
            if isinstance(value, (int, float)):
                observed[budget_name] = float(value)

    if (memory_before is None) != (memory_after is None):
        raise ValueError("both --memory-before and --memory-after are required together")
    if memory_before is not None and memory_after is not None:
        if (
            (
                memory_before.get("schema_version") != 2
                or memory_after.get("schema_version") != 2
            )
            and not allow_scenario_mismatch
        ):
            raise ValueError("memory budgets require schema v2 profiler artifacts")
        same_memory_identity(memory_before, memory_after)
        before_metadata = memory_before.get("metadata", {})
        after_metadata = memory_after.get("metadata", {})
        before_scenario = (
            before_metadata.get("scenario") if isinstance(before_metadata, dict) else None
        )
        after_scenario = (
            after_metadata.get("scenario") if isinstance(after_metadata, dict) else None
        )
        before_words = set(
            str(before_scenario or "").lower().replace("_", "-").split("-")
        )
        after_words = set(
            str(after_scenario or "").lower().replace("_", "-").split("-")
        )
        if not allow_scenario_mismatch and (
            not {"overview", "before"}.issubset(before_words)
            or not {"overview", "after", "skills"}.issubset(after_words)
        ):
            raise ValueError(
                "Skills view-cycle memory budgets require an Overview-before scenario "
                "and an Overview-after-Skills scenario"
            )
        before_malloc = memory_before.get("malloc", {})
        after_malloc = memory_after.get("malloc", {})
        if not isinstance(before_malloc, dict) or not isinstance(after_malloc, dict):
            raise ValueError("memory artifacts are missing malloc metrics")
        before_allocated = before_malloc.get("allocated_mib")
        after_allocated = after_malloc.get("allocated_mib")
        if not isinstance(before_allocated, (int, float)) or not isinstance(
            after_allocated, (int, float)
        ):
            raise ValueError("memory artifacts are missing live malloc allocations")
        observed["skills_view_cycle_retained_live_heap_delta_mib"] = float(
            after_allocated
        ) - float(before_allocated)
    return observed, gaps


def evaluate(
    budget_document: dict[str, Any],
    observed: dict[str, float],
    gaps: list[str],
    *,
    include_proposed: bool,
    allow_scenario_mismatch: bool = False,
) -> dict[str, Any]:
    budgets = budget_document.get("budgets")
    if budget_document.get("schema_version") != 1 or not isinstance(budgets, dict):
        raise ValueError("budget file is not a supported app performance budget document")
    evaluations: list[dict[str, Any]] = []
    violations: list[str] = []
    for name, specification in budgets.items():
        if not isinstance(specification, dict):
            raise ValueError(f"budget {name} must be an object")
        status = specification.get("status")
        limit = specification.get("limit")
        comparison = specification.get("comparison")
        if status not in {"proposed", "enforced"} or not isinstance(limit, (int, float)):
            raise ValueError(f"budget {name} has invalid status or limit")
        if comparison not in {"max", "min"}:
            raise ValueError(f"budget {name} has unsupported comparison {comparison!r}")
        value = observed.get(name)
        evaluated = value is not None and (status == "enforced" or include_proposed)
        passed = None
        if evaluated:
            passed = value <= float(limit) if comparison == "max" else value >= float(limit)
        evaluations.append(
            {
                "name": name,
                "status": status,
                "limit": float(limit),
                "comparison": comparison,
                "observed": value,
                "evaluated": evaluated,
                "passed": passed,
                "fidelity": specification.get("fidelity"),
            }
        )
        if passed is False:
            violations.append(f"{name}: observed {value:.2f}, limit {float(limit):.2f}")
    return {
        "schema_version": 1,
        "include_proposed": include_proposed,
        "allow_scenario_mismatch": allow_scenario_mismatch,
        "evaluations": evaluations,
        "coverage_gaps": gaps,
        "violations": violations,
    }


def text_summary(result: dict[str, Any]) -> str:
    lines = [
        "mode: " + ("proposed-and-enforced" if result["include_proposed"] else "enforced-only"),
        "scenario_validation: "
        + ("waived" if result.get("allow_scenario_mismatch") else "required"),
    ]
    for item in result["evaluations"]:
        if item["observed"] is None:
            outcome = "not measured"
        elif not item["evaluated"]:
            outcome = f"observed {item['observed']:.2f}; proposed target not enforced"
        else:
            outcome = "pass" if item["passed"] else "FAIL"
            outcome += f"; observed {item['observed']:.2f}, limit {item['limit']:.2f}"
        lines.append(f"{item['name']} [{item['status']}]: {outcome}")
    for gap in result["coverage_gaps"]:
        lines.append(f"coverage_gap: {gap}")
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--budgets",
        type=Path,
        default=Path(__file__).with_name("app-performance-budgets.json"),
    )
    parser.add_argument("--interactions", type=Path, action="append")
    parser.add_argument("--efficiency", type=Path)
    parser.add_argument("--memory-before", type=Path)
    parser.add_argument("--memory-after", type=Path)
    parser.add_argument("--include-proposed", action="store_true")
    parser.add_argument(
        "--allow-scenario-mismatch",
        action="store_true",
        help="Explicitly compare artifacts whose scenario labels do not match the budget protocol.",
    )
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.output is not None and args.output.exists():
        print(f"Output already exists; refusing to replace it: {args.output}", file=sys.stderr)
        return 2
    try:
        observed, gaps = observed_metrics(
            interactions=[read_json(path) for path in args.interactions]
            if args.interactions
            else None,
            efficiency=read_json(args.efficiency) if args.efficiency else None,
            memory_before=read_json(args.memory_before) if args.memory_before else None,
            memory_after=read_json(args.memory_after) if args.memory_after else None,
            allow_scenario_mismatch=args.allow_scenario_mismatch,
        )
        result = evaluate(
            read_json(args.budgets),
            observed,
            gaps,
            include_proposed=args.include_proposed,
            allow_scenario_mismatch=args.allow_scenario_mismatch,
        )
        rendered = text_summary(result)
        if args.output is not None:
            args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
        print(rendered, end="")
        return 1 if result["violations"] else 0
    except (OSError, TypeError, ValueError, json.JSONDecodeError) as error:
        print(error, file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
