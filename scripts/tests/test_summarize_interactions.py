from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "summarize-interactions.py"
SPEC = importlib.util.spec_from_file_location("summarize_interactions", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class SummarizeInteractionsTests(unittest.TestCase):
    def test_summarizes_nearest_rank_latency_and_preserves_fidelity(self) -> None:
        raw = {
            "schema_version": 1,
            "scenario": "tabs",
            "automation": "macos_accessibility",
            "process_name": "Metagent Dev",
            "navigation_button_count": 6,
            "samples": [
                {
                    "metric": "tab_input_to_selected_state_ms",
                    "interaction": f"switch-{index}",
                    "iteration": index,
                    "value_ms": value,
                    "presentation_observed": False,
                }
                for index, value in enumerate([10, 30, 20, 40, 80], start=1)
            ],
            "coverage_gaps": ["No presentation sentinel."],
        }

        result = MODULE.summarize(raw, {"build_commit": "abc123"})
        metric = result["metrics"]["tab_input_to_selected_state_ms"]

        self.assertEqual(metric["minimum"], 10)
        self.assertEqual(metric["median"], 30)
        self.assertEqual(metric["p95"], 80)
        self.assertEqual(metric["maximum"], 80)
        self.assertFalse(metric["all_presentations_observed"])
        self.assertEqual(result["provenance"]["build_commit"], "abc123")
        self.assertIn("coverage_gap: No presentation sentinel.", MODULE.text_summary(result))

    def test_rejects_invalid_or_empty_samples(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "raw.json"
            path.write_text(
                json.dumps({"schema_version": 1, "samples": []}), encoding="utf-8"
            )
            with self.assertRaisesRegex(ValueError, "contains no interaction samples"):
                MODULE.read_raw(path)

            path.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "samples": [{"metric": "tabs", "value_ms": -1}],
                    }
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "invalid interaction duration"):
                MODULE.read_raw(path)


if __name__ == "__main__":
    unittest.main()
