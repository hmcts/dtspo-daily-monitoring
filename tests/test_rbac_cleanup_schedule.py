import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]
SATURDAY_SCHEDULE = "Saturday morning daily checks and RBAC cleanup"
WEEKDAY_SCHEDULE = "Runs 8 AM & 3 PM Mon-Fri"


class RbacCleanupScheduleTests(unittest.TestCase):
    def run_audit(self, reason="Schedule", branch="refs/heads/master",
                  schedule=SATURDAY_SCHEDULE, requested=True):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts = root / "scripts"
            scripts.mkdir()
            shutil.copyfile(
                REPOSITORY / "scripts/rbac-privileged-role-audit.sh",
                scripts / "rbac-privileged-role-audit.sh",
            )
            (scripts / "common-functions.sh").write_text("")
            # Stop at the first Python call, before any Azure or Slack access.
            python = root / "python3"
            python.write_text(
                '#!/bin/sh\nprintf "cleanup=%s\\n" "$3"\nexit 42\n'
            )
            # Provide GNU getopt-style quoting without depending on macOS getopt.
            getopt = root / "getopt"
            getopt.write_text(
                f"#!{sys.executable}\n"
                "import shlex, sys\n"
                'print(shlex.join(sys.argv[sys.argv.index("--") + 1:] + ["--"]))\n'
            )
            for executable in (python, getopt):
                executable.chmod(0o755)
            arguments = [
                "bash", "scripts/rbac-privileged-role-audit.sh",
                "--slackBotToken", "test-token",
                "--slackChannelName", "test-channel",
            ]
            if requested:
                arguments.append("--remove-direct")
            result = subprocess.run(
                arguments,
                cwd=root,
                env={
                    **os.environ,
                    "PATH": f"{root}:{os.environ['PATH']}",
                    "BUILD_REASON": reason,
                    "BUILD_SOURCEBRANCH": branch,
                    "BUILD_CRONSCHEDULE_DISPLAYNAME": schedule,
                },
                capture_output=True,
                text=True,
                timeout=10,
            )
            self.assertEqual(result.returncode, 42, result.stdout + result.stderr)
            return result.stdout

    def test_saturday_schedule_on_master_enables_cleanup(self):
        self.assertIn("cleanup=true", self.run_audit())

    def test_other_runs_remain_read_only(self):
        for overrides in (
            {"schedule": WEEKDAY_SCHEDULE},
            {"schedule": ""},
            {"schedule": "Other Saturday schedule"},
            {"reason": "Manual"},
            {"reason": "PullRequest", "branch": "refs/pull/123/merge"},
            {"branch": "refs/heads/feature"},
            {"reason": "", "branch": "", "schedule": ""},
        ):
            with self.subTest(**overrides):
                output = self.run_audit(**overrides)
                self.assertIn("cleanup=false", output)
                self.assertIn("running the audit only", output)

    def test_cleanup_requires_explicit_flag_even_on_saturday_schedule(self):
        self.assertIn("cleanup=false", self.run_audit(requested=False))

    def test_pipeline_schedules_and_cleanup_invocation(self):
        pipeline = (REPOSITORY / "azure-pipelines.yaml").read_text()
        schedules = pipeline.split("schedules:\n", 1)[1].split("\nparameters:", 1)[0]
        entries = re.findall(
            r"  - cron: '([^']+)'\n"
            r"    displayName: ([^\n]+)\n"
            r"    branches:\n"
            r"      include:\n"
            r"        - master\n"
            r"    always: 'true'",
            schedules,
        )
        self.assertEqual(entries, [
            ("45 7,14 * * Mon-Fri", WEEKDAY_SCHEDULE),
            ("45 7 * * Sat", SATURDAY_SCHEDULE),
        ])
        self.assertEqual(schedules.count("  - cron:"), len(entries))
        self.assertIn("template: jobs/role-assignment-checks.yaml", pipeline)
        role_checks = (REPOSITORY / "jobs/role-assignment-checks.yaml").read_text()
        task = re.search(
            r"      - task: AzureCLI@2\n"
            r"(?:(?!      - task:).)*"
            r"scriptPath: scripts/rbac-privileged-role-audit.sh\n"
            r"(?:(?!      - task:).)*",
            role_checks,
            re.DOTALL,
        )
        self.assertIsNotNone(task)
        self.assertIn("azureSubscription: 'GA-Prod-Tenant'", task.group())
        self.assertIn("--remove-direct", task.group())
        self.assertNotIn("condition:", task.group())


if __name__ == "__main__":
    unittest.main()
