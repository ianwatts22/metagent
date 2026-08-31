from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


VERIFY = Path(__file__).parents[2] / "scripts/verify.sh"


class VerifyDiagnosticsTests(unittest.TestCase):
    def run_fixture(self, fixture: str) -> subprocess.CompletedProcess[str]:
        source = VERIFY.read_text(encoding="utf-8")
        # Exercise the production stage wrapper, not a duplicated trap.
        wrapper = "run_stage() {" + source.split("run_stage() {", 1)[1].split(
            "run_fast_lane() {", 1
        )[0]
        with tempfile.TemporaryDirectory() as directory:
            script = f'''set -euo pipefail
log_root="$METAGENT_TEST_LOG_ROOT"
stage_number=0
{wrapper}
{fixture}
run_stage "fixture" "" fixture
'''
            return subprocess.run(
                # Explicitly cover macOS's stock Bash 3.2 even when Homebrew's
                # newer bash appears first on the developer's PATH.
                ["/bin/bash", "-c", script],
                env={**os.environ, "METAGENT_TEST_LOG_ROOT": directory},
                capture_output=True,
                text=True,
                check=False,
            )

    def test_failed_nested_assertion_reports_function_without_fixture_values(self) -> None:
        result = self.run_fixture('''
fixture() (
  value=private-fixture-value
  test "$value" = expected
)
''')
        self.assertEqual(result.returncode, 1)
        self.assertIn("Verification failed in bash (fixture)", result.stderr)
        self.assertNotRegex(result.stderr, r"bash:[0-9]+")
        self.assertNotIn("private-fixture-value", result.stderr)

    def test_expected_failure_in_conditional_does_not_fail_the_stage(self) -> None:
        result = self.run_fixture('''
fixture() (
  if false; then exit 9; fi
  true
)
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("Verification failed in", result.stdout + result.stderr)

    def test_fixture_path_normalization_on_stock_bash(self) -> None:
        source = VERIFY.read_text(encoding="utf-8")
        assignment = next(
            line for line in source.splitlines()
            if line.startswith("normalized_fixture_root=")
        )
        result = subprocess.run(
            ["/bin/bash", "-c", f'''set -eu
fixture_root="/private/tmp/fixture with spaces"
{assignment}
printf '%s' "$normalized_fixture_root"
'''],
            capture_output=True,
            text=True,
            check=True,
        )
        self.assertEqual(result.stdout, "/tmp/fixture with spaces")


if __name__ == "__main__":
    unittest.main()
