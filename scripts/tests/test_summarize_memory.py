from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "summarize-memory.py"
PROFILE_SCRIPT = Path(__file__).parents[1] / "profile-app-memory.sh"
SPEC = importlib.util.spec_from_file_location("summarize_memory", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


VMMAP_SUMMARY = """
Process:         MetagentMenuBar [4242]
Path:            /Users/USER/Applications/Metagent Dev.app/Contents/MacOS/MetagentMenuBar
Identifier:      com.ianwatts.metagent.menu-bar.dev
Version:         0.0.0-dev (0)
Date/Time:       2026-08-28 17:24:03.659 -0700
Launch Time:     2026-08-28 15:19:21.400 -0700
OS Version:      macOS 27.0 (26A5416b)

Physical footprint:         223.7M
Physical footprint (peak):  1.2G

                                          VIRTUAL   RESIDENT      DIRTY    SWAPPED ALLOCATION      BYTES DIRTY+SWAP          REGION
MALLOC ZONE                                  SIZE       SIZE       SIZE       SIZE      COUNT  ALLOCATED  FRAG SIZE  % FRAG   COUNT
===========                               =======  =========  =========  =========  =========  =========  =========  ======  ======
DefaultMallocZone_0x1038c0000              281.8M     135.8M     133.8M      40.3M     571711      84.6M      89.5M     52%     456
AttributeGraph_0x7a4a864460                 16.0M      12.2M      12.1M        32K     292652       9.9M      2338K     19%       3
===========                               =======  =========  =========  =========  =========  =========  =========  ======  ======
TOTAL                                      306.7M     153.0M     150.9M      43.5M     900479     100.0M      94.5M     49%     843
"""


def sample_with(*, footprint: str, allocated: str, allocation_count: int, captured_at: str) -> str:
    return (
        VMMAP_SUMMARY
        .replace("223.7M", footprint)
        .replace("100.0M", allocated)
        .replace("900479", str(allocation_count))
        .replace("2026-08-28 17:24:03.659 -0700", captured_at)
    )


class SummarizeMemoryTests(unittest.TestCase):
    def test_parses_physical_malloc_process_and_fragmentation_metrics(self) -> None:
        result = MODULE.parse_vmmap_summary(VMMAP_SUMMARY)

        self.assertEqual(result["captured_at"], "2026-08-28 17:24:03.659 -0700")
        self.assertEqual(result["physical"]["footprint_mib"], 223.7)
        self.assertEqual(
            result["physical"]["process_lifetime_peak_footprint_mib"], 1228.8
        )
        self.assertEqual(result["malloc"]["allocated_mib"], 100.0)
        self.assertEqual(result["malloc"]["resident_mib"], 153.0)
        self.assertEqual(result["malloc"]["fragmentation_mib"], 94.5)
        self.assertEqual(result["malloc"]["allocation_count"], 900479)
        self.assertEqual(result["process"]["identifier"], "com.ianwatts.metagent.menu-bar.dev")
        self.assertEqual(result["process"]["version"], "0.0.0-dev (0)")
        self.assertEqual(result["process"]["os_version"], "macOS 27.0 (26A5416b)")

    def test_summarizes_odd_samples_with_medians_ranges_and_metadata(self) -> None:
        samples = [
            MODULE.parse_vmmap_summary(sample_with(
                footprint="120.0M",
                allocated="30.0M",
                allocation_count=300,
                captured_at="2026-08-28 17:24:01.000 -0700",
            )),
            MODULE.parse_vmmap_summary(sample_with(
                footprint="150.0M",
                allocated="50.0M",
                allocation_count=500,
                captured_at="2026-08-28 17:24:02.000 -0700",
            )),
            MODULE.parse_vmmap_summary(sample_with(
                footprint="130.0M",
                allocated="40.0M",
                allocation_count=400,
                captured_at="2026-08-28 17:24:03.000 -0700",
            )),
        ]
        result = MODULE.summarize(
            samples,
            channel="dev",
            pid=4242,
            scenario="skills-after-settle",
            executable_path="/Users/test/Applications/Metagent Dev.app/Contents/MacOS/MetagentMenuBar",
            executable_sha256="abc123",
            settle_seconds=5,
            sample_interval_seconds=1,
        )

        self.assertEqual(result["schema_version"], 2)
        self.assertEqual(result["metadata"]["scenario"], "skills-after-settle")
        self.assertEqual(result["metadata"]["executable_sha256"], "abc123")
        self.assertEqual(result["metadata"]["sample_count"], 3)
        self.assertEqual(result["metadata"]["capture_started_at"], "2026-08-28 17:24:01.000 -0700")
        self.assertEqual(result["metadata"]["capture_finished_at"], "2026-08-28 17:24:03.000 -0700")
        self.assertEqual(result["physical"]["footprint_mib"], 130.0)
        self.assertEqual(result["physical"]["footprint_range_mib"], {"min": 120.0, "max": 150.0})
        self.assertEqual(
            result["physical"]["process_lifetime_peak_footprint_mib"], 1228.8
        )
        self.assertEqual(result["malloc"]["allocated_mib"], 40.0)
        self.assertEqual(result["malloc"]["allocation_count"], 400)
        self.assertEqual(
            result["malloc"]["ranges"]["allocated_mib"],
            {"min": 30.0, "max": 50.0},
        )
        self.assertEqual(len(result["samples"]), 3)
        self.assertIn(
            "process_lifetime_peak_physical_footprint_mib",
            MODULE.text_summary(result),
        )

    def test_rejects_incomplete_or_even_sample_sets(self) -> None:
        with self.assertRaisesRegex(ValueError, "malloc zone table"):
            MODULE.parse_vmmap_summary("Physical footprint: 2M")

        without_total = VMMAP_SUMMARY.rsplit("TOTAL", maxsplit=1)[0]
        with self.assertRaisesRegex(ValueError, "malloc zone total"):
            MODULE.parse_vmmap_summary(without_total)

        parsed = MODULE.parse_vmmap_summary(VMMAP_SUMMARY)
        with self.assertRaisesRegex(ValueError, "odd number"):
            MODULE.summarize(
                [parsed, parsed],
                channel="dev",
                pid=4242,
                scenario=None,
                executable_path=None,
                executable_sha256=None,
                settle_seconds=0,
                sample_interval_seconds=0,
            )

    def test_rejects_samples_from_different_process_launches(self) -> None:
        first = MODULE.parse_vmmap_summary(VMMAP_SUMMARY)
        second = MODULE.parse_vmmap_summary(
            VMMAP_SUMMARY.replace(
                "2026-08-28 15:19:21.400 -0700",
                "2026-08-28 16:00:00.000 -0700",
            )
        )
        with self.assertRaisesRegex(ValueError, "different app processes"):
            MODULE.summarize(
                [first, second, first],
                channel="dev",
                pid=4242,
                scenario="mixed",
                executable_path=None,
                executable_sha256=None,
                settle_seconds=0,
                sample_interval_seconds=0,
            )

    def test_size_conversion_supports_vmmap_units(self) -> None:
        self.assertEqual(MODULE.size_mib("1024K"), 1.0)
        self.assertEqual(MODULE.size_mib("2.5M"), 2.5)
        self.assertEqual(MODULE.size_mib("1.5G"), 1536.0)

    @unittest.skipUnless(sys.platform == "darwin", "memory profiler is macOS-only")
    def test_profile_script_refuses_nonempty_output_before_process_lookup(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "result"
            output.mkdir()
            (output / "before.json").write_text("preserve me", encoding="utf-8")
            completed = subprocess.run(
                [
                    "bash",
                    str(PROFILE_SCRIPT),
                    "--channel",
                    "dev",
                    "--output",
                    str(output),
                ],
                capture_output=True,
                check=False,
                text=True,
            )
            self.assertEqual(
                (output / "before.json").read_text(encoding="utf-8"),
                "preserve me",
            )

        self.assertEqual(completed.returncode, 2)
        self.assertIn("refusing to replace existing artifacts", completed.stderr)


if __name__ == "__main__":
    unittest.main()
