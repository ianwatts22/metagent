from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "summarize-efficiency.py"
SPEC = importlib.util.spec_from_file_location("summarize_efficiency", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class SummarizeEfficiencyTests(unittest.TestCase):
    def write_samples(
        self,
        root: Path,
        rows: list[str],
        header: str = "second,cpu_percent,rss_kib,threads",
    ) -> Path:
        path = root / "samples.csv"
        path.write_text(
            header + "\n" + "\n".join(rows) + "\n",
            encoding="utf-8",
        )
        return path

    def test_summarizes_bursts_percentiles_memory_trend_and_progress(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            samples_path = self.write_samples(
                Path(temporary),
                [
                    "1.0,0.0,102400,4,1000,0,0,0,0",
                    "2.5,0.5,103424,4,1000,0,0,0,0",
                    "3.5,4.0,104448,6,10486760,10485760,8,20480,1",
                    "4.5,6.0,105472,7,10486760,0,4,10240,1",
                    "5.5,2.0,106496,5,10486760,0,0,0,0",
                    "6.5,0.0,107520,4,10486760,0,0,0,0",
                ],
                "second,cpu_percent,rss_kib,threads,processed_usage_bytes,processed_usage_delta_bytes,observed_descendant_reported_cpu_percent,observed_descendant_rss_kib,observed_descendant_processes",
            )
            samples = MODULE.read_samples(samples_path)
            result = MODULE.summarize(
                samples,
                channel="dev",
                pid=4242,
                active_cpu_threshold=1.0,
                processed_usage_bytes=None,
                provenance={"scenario": "idle-overview", "build_commit": "abc123"},
            )

        cpu = result["cpu"]
        memory = result["memory"]
        progress = result["global_usage_progress"]
        descendants = result["observed_descendants"]
        self.assertAlmostEqual(cpu["average_percent"], 12.75 / 6.5)
        self.assertEqual(cpu["time_weighted_p50_percent"], 0.5)
        self.assertEqual(cpu["time_weighted_p95_percent"], 6.0)
        self.assertEqual(cpu["time_weighted_p99_percent"], 6.0)
        self.assertEqual(cpu["active_samples"], 3)
        self.assertAlmostEqual(cpu["active_seconds"], 3.0)
        self.assertAlmostEqual(cpu["active_duty_cycle_percent"], 300 / 6.5)
        self.assertEqual(cpu["longest_active_burst_seconds"], 3.0)
        self.assertAlmostEqual(cpu["estimated_cpu_seconds"], 0.1275)
        self.assertEqual(cpu["high_cpu_threshold_percent"], 20.0)
        self.assertEqual(cpu["high_cpu_burst_count"], 0)
        self.assertEqual(cpu["high_cpu_bursts_over_one_second"], 0)
        self.assertEqual(cpu["longest_high_cpu_burst_seconds"], 0.0)
        self.assertAlmostEqual(memory["time_weighted_average_rss_mib"], 665.5 / 6.5)
        self.assertEqual(memory["time_weighted_p95_rss_mib"], 105.0)
        self.assertEqual(memory["peak_rss_mib"], 105.0)
        self.assertEqual(memory["rss_growth_mib"], 5.0)
        self.assertAlmostEqual(memory["rss_trend_mib_per_minute"], 55.670103092783506)
        self.assertEqual(result["threads"]["peak"], 7)
        self.assertEqual(progress["global_processed_usage_mib"], 10.0)
        self.assertAlmostEqual(
            progress["global_processed_usage_mib_per_second"], 10 / 6.5
        )
        self.assertEqual(progress["scope"], "shared_database_global")
        self.assertEqual(progress["global_progress_sample_count"], 1)
        self.assertAlmostEqual(progress["global_progress_observed_seconds"], 1.0)
        self.assertAlmostEqual(
            progress["global_progress_observed_duty_cycle_percent"], 100 / 6.5
        )
        self.assertEqual(progress["largest_global_progress_interval_mib"], 10.0)
        self.assertNotIn("cpu_seconds_per_processed_mib", progress)
        self.assertNotIn(
            "selected_app_cpu_seconds_in_progress_intervals", progress
        )
        self.assertEqual(descendants["scope"], "point_in_time_samples_only")
        self.assertFalse(descendants["captures_processes_between_samples"])
        self.assertEqual(descendants["sample_peak_reported_cpu_percent"], 8.0)
        self.assertEqual(descendants["sample_peak_rss_mib"], 20.0)
        self.assertEqual(descendants["sample_peak_processes"], 1)
        self.assertEqual(result["measurement"]["actual_elapsed_seconds"], 6.5)
        self.assertEqual(result["provenance"]["scenario"], "idle-overview")

        summary = MODULE.text_summary(result)
        self.assertIn("global_usage_progress_scope: shared_database_global", summary)
        self.assertIn("observed_descendants_capture_between_samples: false", summary)
        self.assertNotIn("cpu_seconds_per_processed_mib", summary)
        self.assertIn("high_cpu_bursts_over_one_second: 0", summary)

    def test_counts_contiguous_high_cpu_bursts_by_elapsed_time(self) -> None:
        samples = [
            MODULE.ProcessSample(second=0.4, cpu_percent=25, rss_kib=1024, threads=1),
            MODULE.ProcessSample(second=1.2, cpu_percent=30, rss_kib=1024, threads=1),
            MODULE.ProcessSample(second=2.2, cpu_percent=0, rss_kib=1024, threads=1),
            MODULE.ProcessSample(second=2.7, cpu_percent=50, rss_kib=1024, threads=1),
            MODULE.ProcessSample(second=3.2, cpu_percent=0, rss_kib=1024, threads=1),
        ]
        result = MODULE.summarize(
            samples,
            channel="dev",
            pid=42,
            active_cpu_threshold=2,
            high_cpu_threshold=20,
            processed_usage_bytes=None,
        )

        cpu = result["cpu"]
        self.assertEqual(cpu["high_cpu_burst_count"], 2)
        self.assertEqual(cpu["high_cpu_bursts_over_one_second"], 1)
        self.assertAlmostEqual(cpu["longest_high_cpu_burst_seconds"], 1.2)

    def test_isolated_high_sample_is_not_a_sustained_burst(self) -> None:
        result = MODULE.summarize(
            [
                MODULE.ProcessSample(
                    second=1.08, cpu_percent=25, rss_kib=1024, threads=1
                ),
                MODULE.ProcessSample(
                    second=2.16, cpu_percent=0, rss_kib=1024, threads=1
                ),
                MODULE.ProcessSample(
                    second=3.24, cpu_percent=30, rss_kib=1024, threads=1
                ),
                MODULE.ProcessSample(
                    second=4.32, cpu_percent=0, rss_kib=1024, threads=1
                ),
            ],
            channel="dev",
            pid=1,
            active_cpu_threshold=2,
            processed_usage_bytes=None,
            high_cpu_threshold=20,
        )

        cpu = result["cpu"]
        self.assertEqual(cpu["high_cpu_burst_count"], 2)
        self.assertEqual(cpu["high_cpu_bursts_over_one_second"], 0)
        self.assertAlmostEqual(cpu["longest_high_cpu_burst_seconds"], 1.08)

    def test_percentiles_weight_each_cpu_interval_by_elapsed_time(self) -> None:
        samples = [
            MODULE.ProcessSample(second=1, cpu_percent=100, rss_kib=2048, threads=1),
            MODULE.ProcessSample(second=11, cpu_percent=0, rss_kib=1024, threads=1),
        ]
        result = MODULE.summarize(
            samples,
            channel="prod",
            pid=99,
            active_cpu_threshold=1,
            processed_usage_bytes=None,
        )

        self.assertEqual(result["cpu"]["time_weighted_p50_percent"], 0)
        self.assertEqual(result["cpu"]["time_weighted_p95_percent"], 100)
        self.assertAlmostEqual(result["cpu"]["average_percent"], 100 / 11)
        self.assertEqual(result["memory"]["time_weighted_p95_rss_mib"], 2)

    def test_rejects_empty_or_non_monotonic_samples(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            empty = self.write_samples(root, [])
            with self.assertRaisesRegex(ValueError, "no process samples"):
                MODULE.read_samples(empty)

            backwards = self.write_samples(root, ["2,0,100,2", "1,0,100,2"])
            with self.assertRaisesRegex(ValueError, "increase monotonically"):
                MODULE.read_samples(backwards)


if __name__ == "__main__":
    unittest.main()
