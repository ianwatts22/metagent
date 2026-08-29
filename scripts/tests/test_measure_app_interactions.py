from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).parents[2]
SCRIPT = REPO_ROOT / "scripts" / "measure-app-interactions.sh"


class MeasureAppInteractionsScriptTests(unittest.TestCase):
    def test_help_describes_truthful_tab_and_launch_scope(self) -> None:
        completed = subprocess.run(
            [str(SCRIPT), "--help"],
            cwd=REPO_ROOT,
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("selected-state latency, not full", completed.stdout)
        self.assertIn("launch-cold requires it to be stopped", completed.stdout)

    def test_rejects_unknown_scenario_before_touching_the_app(self) -> None:
        completed = subprocess.run(
            [str(SCRIPT), "--scenario", "visual-magic"],
            cwd=REPO_ROOT,
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(completed.returncode, 2)
        self.assertIn("Scenario must be", completed.stderr)

    def test_rejects_multiple_cold_launch_iterations(self) -> None:
        completed = subprocess.run(
            [str(SCRIPT), "--scenario", "launch-cold", "--iterations", "2"],
            cwd=REPO_ROOT,
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(completed.returncode, 2)
        self.assertIn("every later launch would be warm", completed.stderr)

    @unittest.skipUnless(sys.platform == "darwin", "interaction harness is macOS-only")
    def test_refuses_to_overwrite_existing_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "result"
            output.mkdir()
            (output / "before.json").write_text("preserve me", encoding="utf-8")
            completed = subprocess.run(
                [str(SCRIPT), "--output", str(output)],
                cwd=REPO_ROOT,
                text=True,
                capture_output=True,
                check=False,
            )

        self.assertEqual(completed.returncode, 2)
        self.assertIn("refusing to replace existing artifacts", completed.stderr)


if __name__ == "__main__":
    unittest.main()
