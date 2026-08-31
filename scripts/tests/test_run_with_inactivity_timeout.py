from __future__ import annotations

import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).parents[2]
SCRIPT = REPO_ROOT / "scripts" / "run-with-inactivity-timeout.py"


class RunWithInactivityTimeoutTests(unittest.TestCase):
    def run_helper(
        self, command: list[str], timeout: float
    ) -> tuple[subprocess.CompletedProcess[str], str, float]:
        with tempfile.TemporaryDirectory() as temporary:
            stdout_path = Path(temporary) / "stdout"
            started = time.monotonic()
            completed = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--inactivity-timeout",
                    str(timeout),
                    "--termination-grace",
                    "0.1",
                    "--stdout",
                    str(stdout_path),
                    "--",
                    *command,
                ],
                cwd=REPO_ROOT,
                text=True,
                capture_output=True,
                check=False,
                timeout=5,
            )
            elapsed = time.monotonic() - started
            stdout = stdout_path.read_text(encoding="utf-8")
        return completed, stdout, elapsed

    def test_forwards_success_stdout_stderr_and_exit_status(self) -> None:
        completed, stdout, _elapsed = self.run_helper(
            [
                sys.executable,
                "-c",
                "import sys; print('raw-json'); print('progress', file=sys.stderr)",
            ],
            timeout=1,
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(stdout, "raw-json\n")
        self.assertEqual(completed.stderr, "progress\n")

    def test_stderr_activity_resets_timeout(self) -> None:
        # Exercise heartbeat renewal, not the shared runner's ability to
        # schedule a child within 150 ms. Keep total runtime above the timeout
        # so this still fails if activity stops extending the deadline.
        completed, stdout, elapsed = self.run_helper(
            [
                sys.executable,
                "-u",
                "-c",
                (
                    "import sys,time; "
                    "[(print(f'tick-{i}', file=sys.stderr), time.sleep(.05)) "
                    "for i in range(40)]; print('done')"
                ),
            ],
            timeout=1,
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertGreater(elapsed, 1.5)
        self.assertEqual(stdout, "done\n")
        self.assertIn("tick-39", completed.stderr)

    def test_inactivity_terminates_the_process_group_with_timeout_status(self) -> None:
        completed, stdout, elapsed = self.run_helper(
            [
                sys.executable,
                "-u",
                "-c",
                "import sys,time; print('starting', file=sys.stderr); time.sleep(30)",
            ],
            timeout=0.2,
        )

        self.assertEqual(completed.returncode, 124, completed.stderr)
        self.assertLess(elapsed, 2)
        self.assertEqual(stdout, "")
        self.assertIn("starting", completed.stderr)
        self.assertIn("produced no progress", completed.stderr)
        self.assertIn("terminating its process group", completed.stderr)

    def test_closed_stderr_waits_without_a_readable_eof_spin(self) -> None:
        completed, stdout, elapsed = self.run_helper(
            [
                sys.executable,
                "-u",
                "-c",
                "import os,time; os.close(2); time.sleep(30)",
            ],
            timeout=0.2,
        )

        self.assertEqual(completed.returncode, 124, completed.stderr)
        self.assertGreaterEqual(elapsed, 0.18)
        self.assertLess(elapsed, 2)
        self.assertEqual(stdout, "")
        self.assertIn("produced no progress", completed.stderr)
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertIn("selector.unregister(stderr_fd)", source)

    def test_terminating_wrapper_also_stops_descendants(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            temporary_path = Path(temporary)
            stdout_path = temporary_path / "stdout"
            escaped_marker = temporary_path / "descendant-escaped"
            descendant = (
                "import pathlib,signal,time; "
                "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
                "time.sleep(.6); "
                f"pathlib.Path({str(escaped_marker)!r}).write_text('escaped')"
            )
            parent = (
                "import subprocess,sys,time; "
                f"subprocess.Popen([sys.executable, '-c', {descendant!r}]); "
                "print('ready', file=sys.stderr, flush=True); time.sleep(30)"
            )
            process = subprocess.Popen(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--inactivity-timeout",
                    "10",
                    "--termination-grace",
                    "0.1",
                    "--stdout",
                    str(stdout_path),
                    "--",
                    sys.executable,
                    "-u",
                    "-c",
                    parent,
                ],
                cwd=REPO_ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            assert process.stderr is not None
            self.assertEqual(process.stderr.readline(), "ready\n")
            process.terminate()
            _stdout, stderr = process.communicate(timeout=3)
            time.sleep(0.7)

            self.assertEqual(process.returncode, 143, stderr)
            self.assertFalse(escaped_marker.exists(), stderr)


if __name__ == "__main__":
    unittest.main()
