from __future__ import annotations

import csv
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).parents[2]
SCRIPT = REPO_ROOT / "scripts" / "measure-app-efficiency.sh"


class MeasureAppEfficiencyIntegrationTests(unittest.TestCase):
    def write_executable(self, path: Path, body: str) -> None:
        path.write_text("#!/usr/bin/env bash\nset -euo pipefail\n" + body, encoding="utf-8")
        path.chmod(0o755)

    def test_sampler_writes_complete_csv_text_and_json_reports(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fake_bin = root / "bin"
            fake_home = root / "home"
            output = root / "output"
            fake_bin.mkdir()
            usage_database = (
                fake_home / "Library" / "Application Support" / "Metagent" / "usage.sqlite"
            )
            usage_database.parent.mkdir(parents=True)
            usage_database.touch()
            executable = (
                fake_home
                / "Applications"
                / "Metagent Dev.app"
                / "Contents"
                / "MacOS"
                / "MetagentMenuBar"
            )
            executable.parent.mkdir(parents=True)
            executable.touch()
            (executable.parents[1] / "Info.plist").touch()

            self.write_executable(
                fake_bin / "pgrep",
                'if [[ "${1:-}" == "-P" ]]; then exit 1; fi\n'
                'if [[ "$*" == *"Metagent Dev.app"* ]]; then printf "4242\\n"; exit; fi\n'
                'if [[ "$*" == *"Metagent.app"* ]]; then printf "4343\\n"; exit; fi\n'
                "exit 1\n",
            )
            self.write_executable(
                fake_bin / "sleep",
                ":\n",
            )
            self.write_executable(
                fake_bin / "sample",
                'while (($#)); do\n'
                '  if [[ "$1" == "-file" ]]; then printf "fixture stack\\n" >"$2"; exit; fi\n'
                "  shift\n"
                "done\n",
            )
            self.write_executable(
                fake_bin / "sqlite3",
                'state="${METAGENT_TEST_STATE}/sqlite-count"\n'
                'count=0\n'
                '[[ -f "$state" ]] && count="$(<"$state")"\n'
                'count=$((count + 1))\n'
                'printf "%s" "$count" >"$state"\n'
                'printf "%s\\n" "$((1000 + count * 1048576))"\n',
            )
            self.write_executable(
                fake_bin / "plutil",
                'case "$2" in\n'
                '  MetagentBuildCommit) printf "test-build\\n" ;;\n'
                '  CFBundleShortVersionString) printf "0.6.0\\n" ;;\n'
                '  CFBundleVersion) printf "6000\\n" ;;\n'
                '  *) exit 1 ;;\n'
                "esac\n",
            )
            self.write_executable(fake_bin / "git", 'printf "test-repo\\n"\n')
            self.write_executable(
                fake_bin / "shasum", 'printf "fixturehash  %s\\n" "${*: -1}"\n'
            )
            self.write_executable(
                fake_bin / "sw_vers",
                'if [[ "$1" == "-productVersion" ]]; then printf "15.6\\n"; else printf "24G84\\n"; fi\n',
            )
            self.write_executable(
                fake_bin / "sysctl",
                'if [[ "$2" == "hw.model" ]]; then printf "MacFixture1,1\\n"; else printf "Fixture CPU\\n"; fi\n',
            )
            self.write_executable(
                fake_bin / "pmset",
                'if [[ "$*" == "-g batt" ]]; then\n'
                '  printf "Now drawing from \'AC Power\'\\n"\n'
                'elif [[ "$*" == "-g therm" ]]; then\n'
                '  printf "CPU_Speed_Limit = 100\\n"\n'
                'else\n'
                '  printf " lowpowermode 0\\n"\n'
                "fi\n",
            )
            self.write_executable(
                fake_bin / "ps",
                'args="$*"\n'
                'if [[ "$args" == *"-o rss="* ]]; then printf "102400\\n"; exit; fi\n'
                'if [[ "$args" == *"-o time="* ]]; then\n'
                '  state="${METAGENT_TEST_STATE}/ps-count"\n'
                '  count=0\n'
                '  [[ -f "$state" ]] && count="$(<"$state")"\n'
                '  count=$((count + 1))\n'
                '  printf "%s" "$count" >"$state"\n'
                '  printf "0:00.%02d\\n" "$count"\n'
                '  exit\n'
                'fi\n'
                'if [[ "$args" == *"-M -p"* ]]; then\n'
                '  printf "header\\nthread-a\\nthread-b\\n"\n'
                '  exit\n'
                'fi\n'
                'printf "unexpected ps arguments: %s\\n" "$args" >&2\n'
                'exit 2\n',
            )

            environment = os.environ.copy()
            environment.update(
                {
                    "HOME": str(fake_home),
                    "METAGENT_TEST_STATE": str(root),
                    "PATH": f"{fake_bin}:{environment['PATH']}",
                    "PYTHONDONTWRITEBYTECODE": "1",
                }
            )
            completed = subprocess.run(
                [
                    str(SCRIPT),
                    "--channel",
                    "dev",
                    "--duration",
                    "2",
                    "--scenario",
                    "idle-overview",
                    "--output",
                    str(output),
                ],
                cwd=REPO_ROOT,
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn("time_weighted_p95_cpu_percent:", completed.stdout)
            self.assertIn("global_usage_progress_sample_count:", completed.stdout)
            self.assertIn(
                "observed_descendants_capture_between_samples: false",
                completed.stdout,
            )
            self.assertIn("json:", completed.stdout)
            self.assertTrue((output / "stack-sample.txt").is_file())
            self.assertTrue((output / "summary.txt").is_file())
            report = json.loads((output / "summary.json").read_text(encoding="utf-8"))
            self.assertEqual(report["samples"], 2)
            self.assertEqual(
                report["global_usage_progress"]["global_progress_sample_count"], 2
            )
            self.assertEqual(
                report["global_usage_progress"]["global_processed_usage_mib"], 2.0
            )
            self.assertNotIn(
                "cpu_seconds_per_processed_mib", report["global_usage_progress"]
            )
            self.assertGreater(report["measurement"]["actual_elapsed_seconds"], 0)
            self.assertEqual(report["provenance"]["scenario"], "idle-overview")
            self.assertEqual(report["provenance"]["repo_commit"], "test-repo")
            self.assertEqual(report["provenance"]["build_commit"], "test-build")
            self.assertEqual(report["provenance"]["executable_sha256"], "fixturehash")
            self.assertEqual(report["provenance"]["os_version"], "15.6")
            self.assertEqual(report["provenance"]["hardware_model"], "MacFixture1,1")
            self.assertEqual(report["provenance"]["power_source"], "AC Power")
            self.assertIn("Now drawing from", report["provenance"]["power_snapshot"])
            self.assertEqual(report["provenance"]["low_power_mode"], "0")
            self.assertEqual(report["provenance"]["other_channel"], "Metagent")
            self.assertTrue(report["provenance"]["other_channel_running_at_start"])
            self.assertEqual(report["provenance"]["other_channel_pid_at_start"], 4343)

            with (output / "process-samples.csv").open(newline="", encoding="utf-8") as source:
                rows = list(csv.DictReader(source))
            self.assertEqual(len(rows), 2)
            self.assertEqual(rows[0]["processed_usage_delta_bytes"], "1048576")
            self.assertEqual(rows[1]["processed_usage_delta_bytes"], "1048576")
            self.assertEqual(rows[0]["observed_descendant_processes"], "0")

    def test_sampler_refuses_to_overwrite_existing_output(self) -> None:
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
