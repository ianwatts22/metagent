from __future__ import annotations

import unittest
from pathlib import Path


WORKFLOW = Path(__file__).parents[2] / ".github/workflows/verify.yml"


class PRVerificationWorkflowTests(unittest.TestCase):
    def test_pull_requests_run_the_complete_existing_gate(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("  pull_request:\n", workflow)
        self.assertIn("run: ./scripts/verify.sh\n", workflow)
        self.assertIn("runs-on: macos-26", workflow)
        self.assertIn("DEVELOPER_DIR: /Applications/Xcode.app/Contents/Developer", workflow)
        self.assertIn("run: brew install librsvg ripgrep\n", workflow)
        self.assertIn("timeout-minutes: 45", workflow)
        self.assertIn("cancel-in-progress: true", workflow)

    def test_pr_checks_do_not_have_release_authority(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("permissions:\n  contents: read\n", workflow)
        self.assertIn("persist-credentials: false", workflow)
        self.assertIn('METAGENT_CODE_SIGN_IDENTITY: "-"', workflow)
        for forbidden in [
            "pull_request_target", "${{ secrets.", "contents: write",
            "gh release", "git push", "./scripts/notarize.sh",
            "./scripts/install-app.sh", "METAGENT_DISTRIBUTION_BUILD",
        ]:
            self.assertNotIn(forbidden, workflow)

    def test_failures_retain_logs_and_performance_evidence(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("if: always()", workflow)
        self.assertIn("uses: actions/upload-artifact@v4", workflow)
        self.assertIn('METAGENT_VERIFY_KEEP_LOGS: "1"', workflow)
        self.assertIn("${{ runner.temp }}/metagent-verify-logs", workflow)
        self.assertIn("${{ runner.temp }}/metagent-performance.json", workflow)
        self.assertIn("retention-days: 14", workflow)

    def test_runner_paths_are_evaluated_in_step_context(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        job_configuration, steps = workflow.split("    steps:\n", 1)
        self.assertNotIn("${{ runner.", job_configuration)
        verification_step = steps.split("- name: Run complete verification\n", 1)[1].split(
            "- name: Preserve verification evidence", 1
        )[0]
        self.assertIn("        env:\n", verification_step)
        self.assertIn("METAGENT_PERFORMANCE_RESULT_PATH: ${{ runner.temp }}", verification_step)
        self.assertIn("METAGENT_VERIFY_LOG_DIR: ${{ runner.temp }}", verification_step)


if __name__ == "__main__":
    unittest.main()
