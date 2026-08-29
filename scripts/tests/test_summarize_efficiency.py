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
                "second,cpu_percent,rss_kib,threads,processed_usage_bytes,processed_usage_delta_bytes,child_cpu_percent,child_rss_kib,child_processes",
            )
            samples = MODULE.read_samples(samples_path)
            result = MODULE.summarize(
                samples,
                channel="dev",
                pid=4242,
                active_cpu_threshold=1.0,
                processed_usage_bytes=None,
            )

        cpu = result["cpu"]
        memory = result["memory"]
        progress = result["usage_progress"]
        children = result["children"]
        self.assertAlmostEqual(cpu["average_percent"], 12.5 / 6)
        self.assertEqual(cpu["p50_percent"], 0.5)
        self.assertEqual(cpu["p95_percent"], 6.0)
        self.assertEqual(cpu["p99_percent"], 6.0)
        self.assertEqual(cpu["active_samples"], 3)
        self.assertAlmostEqual(cpu["active_seconds"], 3.0)
        self.assertAlmostEqual(cpu["active_duty_cycle_percent"], 300 / 6.5)
        self.assertEqual(cpu["longest_active_burst_seconds"], 3.0)
        self.assertAlmostEqual(cpu["estimated_cpu_seconds"], 0.1275)
        self.assertEqual(memory["average_rss_mib"], 102.5)
        self.assertEqual(memory["peak_rss_mib"], 105.0)
        self.assertEqual(memory["rss_growth_mib"], 5.0)
        self.assertAlmostEqual(memory["rss_trend_mib_per_minute"], 55.670103092783506)
        self.assertEqual(result["threads"]["peak"], 7)
        self.assertEqual(progress["processed_usage_mib"], 10.0)
        self.assertAlmostEqual(progress["cpu_seconds_per_processed_mib"], 0.01275)
        self.assertEqual(progress["scope"], "shared_database")
        self.assertEqual(progress["active_samples"], 1)
        self.assertAlmostEqual(progress["active_seconds"], 1.0)
        self.assertAlmostEqual(progress["active_duty_cycle_percent"], 100 / 6.5)
        self.assertEqual(progress["largest_sample_mib"], 10.0)
        self.assertAlmostEqual(
            progress["selected_app_cpu_seconds_in_progress_intervals"], 0.04
        )
        self.assertEqual(children["peak_reported_cpu_percent"], 8.0)
        self.assertEqual(children["peak_rss_mib"], 20.0)
        self.assertEqual(children["peak_processes"], 1)

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
