from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "summarize-memory.py"
SPEC = importlib.util.spec_from_file_location("summarize_memory", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


VMMAP_SUMMARY = """
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


class SummarizeMemoryTests(unittest.TestCase):
    def test_parses_physical_malloc_and_fragmentation_metrics(self) -> None:
        result = MODULE.parse_vmmap_summary(VMMAP_SUMMARY)

        self.assertEqual(result["schema_version"], 1)
        self.assertEqual(result["physical"]["footprint_mib"], 223.7)
        self.assertEqual(result["physical"]["peak_footprint_mib"], 1228.8)
        self.assertEqual(result["malloc"]["allocated_mib"], 100.0)
        self.assertEqual(result["malloc"]["resident_mib"], 153.0)
        self.assertEqual(result["malloc"]["dirty_mib"], 150.9)
        self.assertEqual(result["malloc"]["swapped_mib"], 43.5)
        self.assertEqual(result["malloc"]["fragmentation_mib"], 94.5)
        self.assertEqual(result["malloc"]["fragmentation_percent"], 49)
        self.assertEqual(result["malloc"]["allocation_count"], 900479)
        self.assertEqual(result["malloc"]["region_count"], 843)

    def test_rejects_incomplete_vmmap_output(self) -> None:
        with self.assertRaisesRegex(ValueError, "malloc zone table"):
            MODULE.parse_vmmap_summary("Physical footprint: 2M")

        without_total = VMMAP_SUMMARY.rsplit("TOTAL", maxsplit=1)[0]
        with self.assertRaisesRegex(ValueError, "malloc zone total"):
            MODULE.parse_vmmap_summary(without_total)

    def test_size_conversion_supports_vmmap_units(self) -> None:
        self.assertEqual(MODULE.size_mib("1024K"), 1.0)
        self.assertEqual(MODULE.size_mib("2.5M"), 2.5)
        self.assertEqual(MODULE.size_mib("1.5G"), 1536.0)


if __name__ == "__main__":
    unittest.main()
