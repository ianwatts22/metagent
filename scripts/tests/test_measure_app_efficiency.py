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

            self.write_executable(
                fake_bin / "pgrep",
                'if [[ "${1:-}" == "-P" ]]; then exit 1; fi\nprintf "4242\\n"\n',
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
                [str(SCRIPT), "--channel", "dev", "--duration", "2", "--output", str(output)],
                cwd=REPO_ROOT,
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn("p95_cpu_percent:", completed.stdout)
            self.assertIn("usage_progress_samples:", completed.stdout)
            self.assertIn("json:", completed.stdout)
            self.assertTrue((output / "stack-sample.txt").is_file())
            self.assertTrue((output / "summary.txt").is_file())
            report = json.loads((output / "summary.json").read_text(encoding="utf-8"))
            self.assertEqual(report["samples"], 2)
            self.assertEqual(report["usage_progress"]["active_samples"], 2)
            self.assertEqual(report["usage_progress"]["processed_usage_mib"], 2.0)

            with (output / "process-samples.csv").open(newline="", encoding="utf-8") as source:
                rows = list(csv.DictReader(source))
            self.assertEqual(len(rows), 2)
            self.assertEqual(rows[0]["processed_usage_delta_bytes"], "1048576")
            self.assertEqual(rows[1]["processed_usage_delta_bytes"], "1048576")
            self.assertEqual(rows[0]["child_processes"], "0")


if __name__ == "__main__":
    unittest.main()
