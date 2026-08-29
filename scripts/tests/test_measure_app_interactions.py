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
        self.assertIn("AX content-ready", completed.stdout)
        self.assertIn("do not claim first-pixel", completed.stdout)
        self.assertIn("common-interactions", completed.stdout)
        self.assertIn("launch-cold requires it to be stopped", completed.stdout)
        self.assertIn("Overview → Skills → Overview", completed.stdout)

    def test_shell_enforces_a_hard_inactivity_watchdog(self) -> None:
        script = SCRIPT.read_text(encoding="utf-8")

        self.assertIn(
            "automation_inactivity_timeout_seconds=$((timeout_seconds + 5))", script
        )
        self.assertIn('scripts/run-with-inactivity-timeout.py', script)
        self.assertIn(
            '--inactivity-timeout "$automation_inactivity_timeout_seconds"', script
        )
        self.assertIn('--stdout "$raw_path"', script)
        self.assertIn('if [[ "$automation_status" == "124" ]]', script)
        self.assertIn('exit "$automation_status"', script)
        for flag in [
            "--probe-source-sha256",
            "--probe-binary-sha256",
            "--probe-compiler-version",
            "--probe-compile-contract",
        ]:
            self.assertIn(flag, script)

        native_probe = (REPO_ROOT / "scripts" / "metagent-ax-probe.swift").read_text(
            encoding="utf-8"
        )
        self.assertIn("AXUIElementSetMessagingTimeout(systemWide", native_probe)
        self.assertIn("AXUIElementSetMessagingTimeout(element", native_probe)
        self.assertIn("heartbeat(description", native_probe)
        self.assertIn("heartbeatIntervalMilliseconds = 1_000", native_probe)
        self.assertNotIn("osascript", script)

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

    def test_skills_cycle_defaults_to_one_iteration(self) -> None:
        script = SCRIPT.read_text(encoding="utf-8")

        self.assertIn('iterations_explicit=false', script)
        self.assertIn('scenario" == "skills-cycle"', script)
        self.assertIn('iterations=1', script)

    def test_skills_cycle_normalizes_and_waits_for_summary_table(self) -> None:
        script = (REPO_ROOT / "scripts" / "metagent-ax-probe.swift").read_text(
            encoding="utf-8"
        )

        self.assertIn('"metagent.skills.view.summary"', script)
        self.assertIn('contentReadyPrefix("Skills")', script)
        skills_cycle = script.split("private func runSkillsCycle", 1)[1].split(
            "private func runRefresh", 1
        )[0]
        self.assertIn("probe.normalizeSkillsSummary(window: window)", skills_cycle)
        self.assertIn('"presentation_observed": true', script)

    def test_ready_tokens_include_the_actual_sort_descriptor(self) -> None:
        source_root = REPO_ROOT / "apps" / "MetagentMenuBar" / "Sources"
        for name in [
            "InventorySection.swift",
            "MCPInventorySection.swift",
            "PluginsSection.swift",
            "ProjectsSection.swift",
        ]:
            source = (source_root / name).read_text(encoding="utf-8")
            self.assertIn("sortPresentationState(sortOrder)", source, name)
            self.assertNotIn("sortRevision", source, name)

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
