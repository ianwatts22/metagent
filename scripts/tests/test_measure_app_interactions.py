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
        self.assertIn("[metagent-perf]", script)
        self.assertIn("console.log", script)
        self.assertIn("function findSortableHeader", script)
        self.assertIn('if (role === "AXRow")', script)
        self.assertIn("visited < maximumVisited", script)
        self.assertIn("preferredCursor < preferred.length", script)
        self.assertIn("children.length - 1", script)
        self.assertNotIn("children.sort", script)
        self.assertNotIn(
            'findDescendantByRoleAndName(window, "AXButton", headerName, true)',
            script,
        )
        self.assertIn("findSortableHeader(currentContent, headerName)", script)
        self.assertIn("findSortableHeader(window, headerName)", script)
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

    def test_ax_walks_are_bounded_indexed_queues_without_array_shift(self) -> None:
        script = (REPO_ROOT / "scripts" / "measure-metagent-interactions.js").read_text(
            encoding="utf-8"
        )

        self.assertIn("const maximumAccessibilityTraversalElements = 8192", script)
        self.assertGreaterEqual(script.count("let cursor = 0;"), 3)
        self.assertGreaterEqual(
            script.count("cursor < pending.length && cursor < maximumVisited"), 3
        )
        self.assertIn("let preferredCursor = 0;", script)
        self.assertIn("let ordinaryCursor = 0;", script)
        self.assertIn("let rowCursor = 0;", script)
        self.assertNotIn(".shift()", script)
        self.assertNotIn("pending.unshift", script)

    def test_filter_and_sort_poll_retained_ax_roots_before_bounded_fallback(self) -> None:
        script = (REPO_ROOT / "scripts" / "measure-metagent-interactions.js").read_text(
            encoding="utf-8"
        )
        filter_measurement = script.split("function chooseMenuOption", 1)[1].split(
            "function measureSort", 1
        )[0]
        sort_measurement = script.split("function measureSort", 1)[1].split(
            "function findReloadControl", 1
        )[0]
        content_wait = script.split("function waitForContentIdentifierChange", 1)[1].split(
            "function menuItem", 1
        )[0]

        self.assertIn("const content = contentElement", filter_measurement)
        self.assertIn("waitForContentIdentifierChange(\n    content,", filter_measurement)
        self.assertIn("elementIdentifier(retainedContent)", content_wait)
        self.assertIn("replacementContentSearchIntervalMilliseconds", content_wait)
        self.assertIn("if (now < nextReplacementSearchAt)", content_wait)
        self.assertIn("findDescendantByIdentifierPrefix(window, prefix)", content_wait)

        self.assertIn("let currentContent = content", sort_measurement)
        self.assertIn("let currentHeader = header", sort_measurement)
        self.assertIn("elementIdentifier(currentContent)", sort_measurement)
        self.assertIn(
            'elementAttributeValue(currentHeader, "AXSortDirection")', sort_measurement
        )
        self.assertIn("findSortableHeader(currentContent, headerName)", sort_measurement)
        self.assertIn("findSortableHeader(window, headerName)", sort_measurement)
        self.assertIn("if (now < nextReplacementSearchAt)", sort_measurement)
        self.assertIn("currentIdentifier !== previous", sort_measurement)
        self.assertIn("currentDirection !== previousDirection", sort_measurement)

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
