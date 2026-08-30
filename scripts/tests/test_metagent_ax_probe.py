from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).parents[2]
PROBE = REPO_ROOT / "scripts" / "metagent-ax-probe.swift"
HARNESS = REPO_ROOT / "scripts" / "measure-app-interactions.sh"


class MetagentAXProbeTests(unittest.TestCase):
    def test_harness_compiles_and_caches_the_native_probe(self) -> None:
        script = HARNESS.read_text(encoding="utf-8")

        self.assertIn('probe_source="$repo_root/scripts/metagent-ax-probe.swift"', script)
        self.assertIn('probe_cache_base="${TMPDIR:-/private/tmp}"', script)
        self.assertIn('metagent-ax-probe-cache-$(id -u)', script)
        self.assertIn('probe_compiler_version="$(xcrun swiftc -version 2>&1 |', script)
        self.assertIn('probe_compile_contract="swiftc:-O:AppKit:ApplicationServices:v1"', script)
        self.assertIn('xcrun swiftc -O', script)
        self.assertIn('/usr/bin/stat -f %u "$probe_cache_root"', script)
        self.assertIn('chmod 700 "$probe_cache_root"', script)
        self.assertIn('|| return 0', script)
        self.assertIn('[[ -L "$probe_binary" ]]', script)
        self.assertLess(
            script.index('[[ -L "$probe_cache_root" ]]'),
            script.index('if [[ ! -x "$probe_binary" ]]'),
        )
        self.assertIn('-- "$probe_binary"', script)
        self.assertNotIn("osascript", script)

    def test_probe_hard_bounds_ax_calls_and_uses_monotonic_time(self) -> None:
        source = PROBE.read_text(encoding="utf-8")

        self.assertIn("AXUIElementSetMessagingTimeout(systemWide", source)
        self.assertIn("AXUIElementSetMessagingTimeout(element", source)
        self.assertIn("DispatchTime.now().uptimeNanoseconds", source)
        self.assertIn("callTimeoutSeconds = Float(min(1.0, max(0.1", source)
        self.assertIn("Last bounded AX error", source)

    def test_probe_uses_exact_identity_and_semantic_identifiers(self) -> None:
        source = PROBE.read_text(encoding="utf-8")

        self.assertIn("normalizedPath(bundleURL) == appPath", source)
        self.assertIn("actualExecutable == expectedExecutablePath", source)
        self.assertIn('"metagent.navigation.\\(section.lowercased())"', source)
        self.assertIn('"metagent.navigation.container"', source)
        self.assertIn('"metagent.skills.view.summary"', source)
        self.assertIn('"metagent.skills.usage-filter"', source)
        self.assertIn('"metagent.mcps.status-filter"', source)
        self.assertIn('"metagent.plugins.show-filter"', source)
        self.assertNotIn("fixed screen", source)

    def test_lifecycle_waits_service_appkit_events_and_validate_registered_pid(self) -> None:
        source = PROBE.read_text(encoding="utf-8")
        wait = source.split("func waitUntil(", 1)[1].split("func mainWindow", 1)[0]
        launch = source.split("func launch()", 1)[1].split("private func sample", 1)[0]

        self.assertIn("waitWithAppKitEvents(", wait)
        self.assertIn("CFRunLoopRunInMode(.defaultMode, interval, true)", source)
        self.assertIn("Thread.isMainThread", source)
        self.assertIn("completion.wait(timeout: .now()) == .success", launch)
        self.assertNotIn("completion.wait(timeout: .now() +", launch)
        self.assertIn('try waitUntil("exact launched process PID', launch)
        self.assertIn("candidate.processIdentifier == application.processIdentifier", launch)
        # The compiled self-test exercises the actual wait without requiring
        # Accessibility access or launching/killing any app.
        self.assertIn("RunLoop.main.perform(inModes: [.default])", source)
        self.assertIn('waitWithAppKitEvents("false predicate"', source)

    def test_content_readiness_search_does_not_materialize_lazy_cells(self) -> None:
        source = PROBE.read_text(encoding="utf-8")
        lookup = source.split("func findByIdentifierPrefix(", 1)[1].split(
            "func waitForIdentifier(", 1
        )[0]
        search = source.split("func findContentSentinel<Node>(", 1)[1].split(
            "private struct SortMeasurement", 1
        )[0]

        self.assertIn("findContentSentinel(", lookup)
        self.assertIn("currentRole == kAXTableRole || currentRole == kAXOutlineRole", search)
        self.assertLess(search.index("hasPrefix(prefix)"), search.index("try children(current)"))
        self.assertIn('currentIdentifier.contains(".content.")', search)
        self.assertIn("try sentinelTraversalSelfTest()", source)
        self.assertIn("Sentinel lookup traversed lazy content children", source)

    def test_common_interactions_require_changed_content_and_sort_state(self) -> None:
        source = PROBE.read_text(encoding="utf-8")
        content_wait = source.split("private func waitForContentChange", 1)[1].split(
            "private func menuItem", 1
        )[0]
        sort_measurement = source.split("func measureSort", 1)[1].split(
            "func contentRole", 1
        )[0]

        self.assertIn("current != previousIdentifier", content_wait)
        self.assertIn("replacementSearchIntervalMilliseconds", content_wait)
        self.assertIn("findByIdentifierPrefix(window, prefix: prefix)", content_wait)
        self.assertIn("currentIdentifier != previousIdentifier", sort_measurement)
        self.assertIn("currentDirection != previousDirection", sort_measurement)
        self.assertIn("kAXSortDirectionAttribute", sort_measurement)
        self.assertIn("findSortableHeader(content, name: headerName)", sort_measurement)
        self.assertIn("findSortableHeader(window, name: headerName)", sort_measurement)
        menu_measurement = source.split("func chooseMenuOption", 1)[1].split(
            "func normalizeSkillsSummary", 1
        )[0]
        self.assertIn("controlHasExpectedValue", menu_measurement)
        self.assertIn("expectedContentState", menu_measurement)
        self.assertIn("retainedIdentifier != previous", menu_measurement)
        self.assertIn("retainedIdentifier?.hasPrefix(expectedPrefix)", menu_measurement)
        self.assertIn("replacementIdentifier != previous", menu_measurement)
        self.assertIn("var nextReplacementSearch = 0.0", menu_measurement)
        self.assertLess(
            menu_measurement.index("nextReplacementSearch = elapsedMilliseconds"),
            menu_measurement.index("if let replacement"),
        )
        self.assertLess(
            menu_measurement.index("let retainedIdentifier"),
            menu_measurement.index("if let replacement"),
        )

    def test_ax_walks_are_bounded_indexed_queues(self) -> None:
        source = PROBE.read_text(encoding="utf-8")

        self.assertIn("maximumTraversalElements = 8_192", source)
        self.assertIn("while cursor < pending.count, cursor < maximumVisited", source)
        self.assertIn("while visited < maximumVisited", source)
        self.assertIn("preferredCursor < preferred.count", source)
        self.assertNotIn("removeFirst", source)

    def test_launch_uses_navigation_sentinel_and_monotonic_phases(self) -> None:
        source = PROBE.read_text(encoding="utf-8")
        launch_measurement = source.split("private func launchToNavigationReady", 1)[1].split(
            "private func runLaunch", 1
        )[0]

        self.assertIn('"metagent.navigation.container"', launch_measurement)
        self.assertLess(
            launch_measurement.index('identifier: "metagent.navigation.container"'),
            launch_measurement.index("navigationButtonCount(window)"),
        )
        for phase in [
            "process_ready_ms",
            "window_ready_ms",
            "navigation_ready_ms",
            "diagnostic_ready_ms",
        ]:
            self.assertGreaterEqual(source.count(phase), 1, phase)
        self.assertIn("max(processReady, timer.elapsedMilliseconds)", launch_measurement)
        self.assertIn("max(windowReady, timer.elapsedMilliseconds)", launch_measurement)
        self.assertIn("max(navigationReady, timer.elapsedMilliseconds)", launch_measurement)

    def test_real_tables_or_outlines_are_required_for_sort_coverage(self) -> None:
        source = PROBE.read_text(encoding="utf-8")
        common = source.split("private func runCommonInteractions", 1)[1].split(
            "private func runSkillsCycle", 1
        )[0]

        self.assertIn("readyRole == kAXTableRole || readyRole == kAXOutlineRole", common)
        self.assertIn('"skipped_sections": skippedSections', common)
        self.assertIn("observed no real sortable AXTable/AXOutline transition", common)
        self.assertIn("preserving retained user state", common)

    def test_sort_toggle_restore_is_an_atomic_pair(self) -> None:
        source = PROBE.read_text(encoding="utf-8")
        sort_loop = source.split('for direction in ["toggle", "restore"]', 1)[1].split(
            "observedSortSamples += pair.count", 1
        )[0]

        self.assertIn("pair.append(sample(", sort_loop)
        self.assertIn("samples.append(contentsOf: pair)", sort_loop)
        self.assertGreater(
            sort_loop.index("samples.append(contentsOf: pair)"),
            sort_loop.index("pair.append(sample("),
        )
        self.assertIn("initialDirection", sort_loop)
        self.assertIn("initialContentIdentifier", sort_loop)
        self.assertIn("measurement.direction == initialDirection", sort_loop)
        self.assertIn(
            "measurement.contentIdentifier == initialContentIdentifier", sort_loop
        )

    def test_artifact_contract_remains_compatible_with_budget_checks(self) -> None:
        source = PROBE.read_text(encoding="utf-8")

        self.assertIn('"schema_version": 1', source)
        self.assertIn('"automation": "macos_accessibility"', source)
        self.assertIn('"automation_driver": "native_swift_axui_element"', source)
        self.assertIn('"tab_input_to_ax_content_ready_ms"', source)
        self.assertIn('"filter_input_to_ax_content_ready_ms"', source)
        self.assertIn('"filter_ax_press_call_ms"', source)
        self.assertIn('"filter_press_return_to_control_state_ms"', source)
        self.assertIn('"filter_press_return_to_semantic_content_ready_ms"', source)
        self.assertIn('"sort_input_to_ax_content_ready_ms"', source)

    @unittest.skipUnless(sys.platform == "darwin", "native AX probe is macOS-only")
    def test_probe_compiles_and_its_platform_independent_self_test_passes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binary = root / "metagent-ax-probe"
            completed = subprocess.run(
                [
                    "xcrun",
                    "swiftc",
                    "-O",
                    "-module-cache-path",
                    str(root / "module-cache"),
                    "-framework",
                    "AppKit",
                    "-framework",
                    "ApplicationServices",
                    str(PROBE),
                    "-o",
                    str(binary),
                ],
                cwd=REPO_ROOT,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self_test = subprocess.run(
                [str(binary), "--self-test"],
                cwd=REPO_ROOT,
                text=True,
                capture_output=True,
                check=False,
            )

        self.assertEqual(self_test.returncode, 0, self_test.stderr)
        self.assertEqual(self_test.stdout.strip(), "metagent-ax-probe self-test passed")


if __name__ == "__main__":
    unittest.main()
