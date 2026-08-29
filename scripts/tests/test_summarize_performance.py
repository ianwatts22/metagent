from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "summarize-performance.py"
SPEC = importlib.util.spec_from_file_location("summarize_performance", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class SummarizePerformanceTests(unittest.TestCase):
    def test_parses_xctest_metrics_and_detects_regression(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            log = root / "performance.log"
            log.write_text(
                "Test Case '-[Tests testRefresh]' measured "
                "[CPU Time, s] average: 0.150, relative standard deviation: 2.000%\n",
                encoding="utf-8",
            )
            current = MODULE.parse_metrics(log)
            baseline = root / "baseline.json"
            baseline.write_text(
                json.dumps({
                    "metrics": [{
                        "test": "testRefresh",
                        "metric": "CPU Time",
                        "unit": "s",
                        "average": 0.1,
                    }]
                }),
                encoding="utf-8",
            )

            regressions = MODULE.compare_metrics(current, baseline, 20)

        self.assertEqual(current[0]["average"], 0.15)
        self.assertEqual(len(regressions), 1)
        self.assertIn("+50.0%", regressions[0])

    def test_provenance_identifies_build_and_measurement_shape(self) -> None:
        provenance = MODULE.system_provenance("abc123", 3)

        self.assertEqual(provenance["git_commit"], "abc123")
        self.assertEqual(provenance["build_configuration"], "release")
        self.assertEqual(provenance["iterations"], 3)
        self.assertTrue(provenance["os_version"])
        self.assertTrue(provenance["architecture"])
        self.assertGreater(provenance["logical_cpu_count"], 0)


if __name__ == "__main__":
    unittest.main()
