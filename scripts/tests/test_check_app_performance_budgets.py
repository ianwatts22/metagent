from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "check-app-performance-budgets.py"
SPEC = importlib.util.spec_from_file_location("check_app_performance_budgets", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)

SUMMARY_SPEC = importlib.util.spec_from_file_location(
    "summarize_efficiency_for_budgets", SCRIPT.parent / "summarize-efficiency.py"
)
assert SUMMARY_SPEC and SUMMARY_SPEC.loader
SUMMARY_MODULE = importlib.util.module_from_spec(SUMMARY_SPEC)
sys.modules[SUMMARY_SPEC.name] = SUMMARY_MODULE
SUMMARY_SPEC.loader.exec_module(SUMMARY_MODULE)


class CheckAppPerformanceBudgetsTests(unittest.TestCase):
    def efficiency(self) -> dict:
        return SUMMARY_MODULE.summarize(
            [
                SUMMARY_MODULE.ProcessSample(1, 0.4, 1024, 2),
                SUMMARY_MODULE.ProcessSample(2, 0.8, 1024, 2),
                SUMMARY_MODULE.ProcessSample(3, 0, 1024, 2),
            ],
            channel="dev",
            pid=4242,
            active_cpu_threshold=2,
            processed_usage_bytes=None,
            provenance={"scenario": "settled-idle-overview"},
        )

    def memory(self, allocated_mib: float, scenario: str) -> dict:
        return {
            "schema_version": 2,
            "metadata": {
                "channel": "dev",
                "pid": 4242,
                "scenario": scenario,
                "executable_path": "/fixture/Metagent",
                "executable_sha256": "abc",
                "app_version": "0.6.0",
                "os_version": "15.6",
                "process_launched_at": "2026-08-28 12:00:00",
                "settle_seconds": 3,
                "sample_count": 3,
                "sample_interval_seconds": 1,
            },
            "malloc": {"allocated_mib": allocated_mib},
        }

    def test_extracts_truthful_metrics_without_promoting_selected_state(self) -> None:
        observed, gaps = MODULE.observed_metrics(
            interactions=[{
                "scenario": "refresh",
                "automation": "macos_accessibility",
                "metrics": {
                    "tab_input_to_selected_state_ms": {"p95": 20},
                    "manual_refresh_to_ready_ms": {
                        "p95": 700,
                        "all_presentations_observed": True,
                    },
                },
                "coverage_gaps": [],
            }],
            efficiency={
                "schema_version": 2,
                "measurement": {"sample_interval_clock": "monotonic"},
                "provenance": {"scenario": "settled-idle-overview"},
                "cpu": {
                    "average_percent": 0.4,
                    "time_weighted_p95_percent": 0.8,
                    "high_cpu_threshold_percent": 20,
                    "high_cpu_bursts_over_one_second": 0,
                }
            },
            memory_before=self.memory(25, "overview-before"),
            memory_after=self.memory(29, "overview-after-skills"),
        )

        self.assertNotIn("common_interaction_input_to_ax_content_ready_p95_ms", observed)
        self.assertEqual(observed["manual_refresh_to_ready_p95_ms"], 700)
        self.assertEqual(observed["settled_overview_average_cpu_percent"], 0.4)
        self.assertEqual(observed["skills_view_cycle_retained_live_heap_delta_mib"], 4)
        self.assertTrue(any("selected-state" in gap for gap in gaps))

    def test_proposed_targets_are_informational_unless_requested(self) -> None:
        budgets = {
            "schema_version": 1,
            "budgets": {
                "metric": {
                    "limit": 1,
                    "comparison": "max",
                    "status": "proposed",
                    "fidelity": "fixture",
                }
            },
        }

        informational = MODULE.evaluate(
            budgets, {"metric": 2}, [], include_proposed=False
        )
        enforced = MODULE.evaluate(budgets, {"metric": 2}, [], include_proposed=True)

        self.assertFalse(informational["evaluations"][0]["evaluated"])
        self.assertEqual(informational["violations"], [])
        self.assertEqual(len(enforced["violations"]), 1)

    def test_accepts_actual_current_efficiency_summary_and_legacy_cpu_shape(self) -> None:
        summary = self.efficiency()
        self.assertEqual(summary["schema_version"], 3)
        for version in (2, 3):
            with self.subTest(schema_version=version):
                artifact = {**summary, "schema_version": version}
                observed, gaps = MODULE.observed_metrics(
                    interactions=None,
                    efficiency=artifact,
                    memory_before=None,
                    memory_after=None,
                )
                self.assertAlmostEqual(observed["settled_overview_average_cpu_percent"], 0.4)
                self.assertEqual(observed["settled_overview_p95_cpu_percent"], 0.8)
                self.assertEqual(observed["settled_overview_high_cpu_bursts_over_1s"], 0)
                self.assertEqual(gaps, [])

    def test_efficiency_compatibility_still_rejects_unknown_versions_and_clocks(self) -> None:
        summary = self.efficiency()
        invalid_artifacts = [
            {**summary, "schema_version": version} for version in (None, 1, 4, "3")
        ] + [
            {**summary, "schema_version": version, "measurement": measurement}
            for version in (2, 3)
            for measurement in (None, {}, {"sample_interval_clock": "wall"})
        ]
        for artifact in invalid_artifacts:
            with self.subTest(artifact=artifact):
                with self.assertRaisesRegex(ValueError, "monotonic sample intervals"):
                    MODULE.observed_metrics(
                        interactions=None,
                        efficiency=artifact,
                        memory_before=None,
                        memory_after=None,
                    )

    def test_current_efficiency_summary_still_requires_settled_overview_and_threshold(self) -> None:
        summary = self.efficiency()
        invalid_artifacts = [
            {**summary, "provenance": {"scenario": "active-usage-backfill"}},
            {**summary, "cpu": {**summary["cpu"], "high_cpu_threshold_percent": 10}},
        ]
        for artifact in invalid_artifacts:
            with self.subTest(artifact=artifact):
                with self.assertRaises(ValueError):
                    MODULE.observed_metrics(
                        interactions=None,
                        efficiency=artifact,
                        memory_before=None,
                        memory_after=None,
                    )

    def test_common_interaction_budget_uses_worst_truthful_ax_ready_p95(self) -> None:
        observed, gaps = MODULE.observed_metrics(
            interactions=[{
                "scenario": "common-interactions",
                "automation": "macos_accessibility",
                "metrics": {
                    "tab_input_to_ax_content_ready_ms": {
                        "p95": 90,
                        "all_presentations_observed": True,
                    },
                    "filter_input_to_ax_content_ready_ms": {
                        "p95": 130,
                        "all_presentations_observed": True,
                    },
                    "sort_input_to_ax_content_ready_ms": {
                        "p95": 110,
                        "all_presentations_observed": True,
                    },
                },
                "coverage_gaps": ["No first-pixel observation."],
            }],
            efficiency=None,
            memory_before=None,
            memory_after=None,
        )

        self.assertEqual(
            observed["common_interaction_input_to_ax_content_ready_p95_ms"], 130
        )
        self.assertEqual(gaps, ["No first-pixel observation."])

    def test_common_interaction_budget_rejects_unobserved_ax_ready_state(self) -> None:
        with self.assertRaisesRegex(ValueError, "did not observe every AX ready state"):
            MODULE.observed_metrics(
                interactions=[{
                    "scenario": "common-interactions",
                    "automation": "macos_accessibility",
                    "metrics": {
                        "tab_input_to_ax_content_ready_ms": {
                            "p95": 90,
                            "all_presentations_observed": True,
                        },
                        "filter_input_to_ax_content_ready_ms": {
                            "p95": 130,
                            "all_presentations_observed": False,
                        },
                        "sort_input_to_ax_content_ready_ms": {
                            "p95": 110,
                            "all_presentations_observed": True,
                        },
                    },
                    "coverage_gaps": [],
                }],
                efficiency=None,
                memory_before=None,
                memory_after=None,
            )

    def test_common_interaction_budget_requires_a_real_sort_metric(self) -> None:
        with self.assertRaisesRegex(
            ValueError, "missing AX content-ready metric sort_input"
        ):
            MODULE.observed_metrics(
                interactions=[{
                    "scenario": "common-interactions",
                    "automation": "macos_accessibility",
                    "metrics": {
                        "tab_input_to_ax_content_ready_ms": {
                            "p95": 90,
                            "all_presentations_observed": True,
                        },
                        "filter_input_to_ax_content_ready_ms": {
                            "p95": 130,
                            "all_presentations_observed": True,
                        },
                    },
                    "skipped_sections": [
                        {"interaction": "sort", "section": "Plugins"}
                    ],
                    "coverage_gaps": [],
                }],
                efficiency=None,
                memory_before=None,
                memory_after=None,
            )

    def test_rejects_memory_comparison_across_processes(self) -> None:
        before = self.memory(25, "overview-before")
        after = self.memory(25, "overview-after")
        after["metadata"]["process_launched_at"] = "2026-08-28 12:01:00"

        with self.assertRaisesRegex(ValueError, "different app processes or builds"):
            MODULE.observed_metrics(
                interactions=None,
                efficiency=None,
                memory_before=before,
                memory_after=after,
            )

    def test_rejects_memory_comparison_with_different_sampling_protocols(self) -> None:
        before = self.memory(25, "overview-before")
        after = self.memory(25, "overview-after-skills")
        after["metadata"]["sample_count"] = 5

        with self.assertRaisesRegex(ValueError, "sample_count"):
            MODULE.observed_metrics(
                interactions=None,
                efficiency=None,
                memory_before=before,
                memory_after=after,
            )

    def test_records_scenario_validation_waiver(self) -> None:
        budgets = {
            "schema_version": 1,
            "budgets": {
                "metric": {
                    "limit": 1,
                    "comparison": "max",
                    "status": "proposed",
                }
            },
        }

        result = MODULE.evaluate(
            budgets,
            {"metric": 1},
            [],
            include_proposed=True,
            allow_scenario_mismatch=True,
        )

        self.assertTrue(result["allow_scenario_mismatch"])
        self.assertIn("scenario_validation: waived", MODULE.text_summary(result))

    def test_rejects_active_work_as_settled_overview(self) -> None:
        with self.assertRaisesRegex(ValueError, "settled Overview CPU budgets require"):
            MODULE.observed_metrics(
                interactions=None,
                efficiency={
                    "schema_version": 2,
                    "measurement": {"sample_interval_clock": "monotonic"},
                    "provenance": {"scenario": "active-usage-backfill"},
                    "cpu": {
                        "average_percent": 0.1,
                        "time_weighted_p95_percent": 0.2,
                        "high_cpu_threshold_percent": 20,
                        "high_cpu_bursts_over_one_second": 0,
                    },
                },
                memory_before=None,
                memory_after=None,
            )

    def test_rejects_wrong_memory_scenario_even_for_same_process(self) -> None:
        before = self.memory(25, "skills-before")
        after = self.memory(25, "skills-after")

        with self.assertRaisesRegex(ValueError, "Overview-before scenario"):
            MODULE.observed_metrics(
                interactions=None,
                efficiency=None,
                memory_before=before,
                memory_after=after,
            )

    def test_rejects_unknown_budget_comparison(self) -> None:
        budgets = {
            "schema_version": 1,
            "budgets": {
                "metric": {
                    "limit": 1,
                    "comparison": "sideways",
                    "status": "proposed",
                }
            },
        }

        with self.assertRaisesRegex(ValueError, "unsupported comparison"):
            MODULE.evaluate(budgets, {"metric": 1}, [], include_proposed=True)


if __name__ == "__main__":
    unittest.main()
