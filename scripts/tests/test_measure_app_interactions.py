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
        script = (REPO_ROOT / "scripts" / "measure-metagent-interactions.js").read_text(
            encoding="utf-8"
        )

        self.assertIn('"metagent.skills.view.summary"', script)
        self.assertIn('contentReadyPrefix("Skills")', script)
        skills_cycle = script.split("function runSkillsCycle", 1)[1].split(
            "function runRefresh", 1
        )[0]
        self.assertIn("normalizeSkillsSummary(window, timeoutMilliseconds)", skills_cycle)
        self.assertNotIn("selectTab(summaryButton", skills_cycle)
        self.assertIn("presentation_observed: true", script)

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

    def test_common_interactions_uses_exact_ids_and_changed_ready_tokens(self) -> None:
        script = (REPO_ROOT / "scripts" / "measure-metagent-interactions.js").read_text(
            encoding="utf-8"
        )

        self.assertIn('"metagent.navigation.overview"', script)
        self.assertIn('"metagent.navigation.projects"', script)
        self.assertIn("waitForContentIdentifierChange", script)
        self.assertIn('"AXSortDirection"', script)
        self.assertIn('metric: "filter_input_to_ax_content_ready_ms"', script)
        self.assertIn('metric: "sort_input_to_ax_content_ready_ms"', script)
        self.assertIn(
            'readyRole !== "AXTable" && readyRole !== "AXOutline"', script
        )
        self.assertIn("skipped_sections: skippedSections", script)
        self.assertIn(
            "observed no real sortable AXTable/AXOutline transition", script
        )
        self.assertNotIn("possibleNavigationRows", script)
        self.assertNotIn("fixed screen coordinates", script)
        self.assertNotIn(".position()", script)

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
