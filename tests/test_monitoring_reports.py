import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]


class MonitoringReportTests(unittest.TestCase):
    def run_sender(self, reports, ready=True, slack_fails=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts = root / "scripts"
            scripts.mkdir()
            for name in ("common-functions.sh", "send-monitoring-reports.sh", "header-block-template.json"):
                shutil.copyfile(REPOSITORY / "scripts" / name, scripts / name)
            report_directory = root / "reports"
            report_directory.mkdir()
            if ready:
                (report_directory / ".ready").touch()
            for index, report in enumerate(reports):
                (report_directory / f"report-{index:04d}").write_text(json.dumps(report))
            curl = root / "curl"
            curl.write_text(
                f"#!{sys.executable}\n"
                '''import json, os, sys
from pathlib import Path
args = sys.argv[1:]
payload = json.loads(args[args.index("--data") + 1])
calls = Path(os.environ["SLACK_CALLS"])
count = len(calls.read_text().splitlines()) if calls.exists() else 0
with calls.open("a") as output:
    output.write(json.dumps(payload) + "\\n")
print(json.dumps({"ok": os.environ["SLACK_FAILS"] != "1", "ts": f"100.{count}", "error": "mock_failure"}))
'''
            )
            curl.chmod(0o755)
            uname = root / "uname"
            uname.write_text("#!/bin/sh\nprintf 'Linux\\n'\n")
            uname.chmod(0o755)
            calls = root / "calls.jsonl"
            result = subprocess.run(
                ["bash", "scripts/send-monitoring-reports.sh", str(report_directory), "test-token", "U123"],
                cwd=root,
                env={
                    **os.environ,
                    "PATH": f"{root}:{os.environ['PATH']}",
                    "SLACK_CALLS": str(calls),
                    "SLACK_FAILS": str(int(slack_fails)),
                },
                capture_output=True,
                text=True,
                timeout=10,
            )
            posts = [json.loads(line) for line in calls.read_text().splitlines()] if calls.exists() else []
            return result, posts

    def test_final_sender_preserves_headers_replies_and_recipient(self):
        result, posts = self.run_sender([
            {"header": "First", "message": "Details", "replies": ["First reply\nNext line", "Second reply"]},
            {"header": "Second", "message": "Other details", "replies": ["Other reply"]},
        ])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(posts), 5)
        self.assertTrue(all(post["channel"] == "U123" for post in posts))
        self.assertEqual(posts[0]["blocks"][0]["text"]["text"], "First")
        self.assertEqual(posts[1]["text"], "First reply\nNext line")
        self.assertEqual(posts[1]["thread_ts"], "100.0")
        self.assertEqual(posts[2]["thread_ts"], "100.0")
        self.assertEqual(posts[3]["blocks"][0]["text"]["text"], "Second")
        self.assertEqual(posts[4]["thread_ts"], "100.3")

    def test_empty_completed_reports_do_not_post(self):
        result, posts = self.run_sender([])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(posts, [])

    def test_sender_interprets_message_escapes_once(self):
        result, posts = self.run_sender([
            {"header": "Test", "message": r"Literal \\n", "replies": [r"Literal \\n"]},
        ])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(posts[0]["blocks"][1]["text"]["text"], r"Literal \n")
        self.assertEqual(posts[1]["text"], r"Literal \n")

    def test_missing_reports_alert_and_fail(self):
        result, posts = self.run_sender([], ready=False)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(len(posts), 1)
        self.assertIn("Monitoring reports unavailable", posts[0]["blocks"][0]["text"]["text"])

    def test_slack_failure_is_not_ignored(self):
        result, posts = self.run_sender([
            {"header": "Test", "message": "Details", "replies": ["Reply"]},
        ], slack_fails=True)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(len(posts), 1)
        self.assertIn("Slack post failed", result.stderr)

    def test_records_separate_headers_and_ordered_replies_without_posting(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(
                [
                    "bash", "-c",
                    '''set -euo pipefail
uname() { printf 'Linux\\n'; }
source "$1/scripts/common-functions.sh"
curl() { echo "Unexpected network call" >&2; return 99; }
recordNotification test-token U123 "First header" 'Details\\nMore details'
first_report=$TS
recordThreadResponse test-token U123 'First reply\\nNext line' "$TS"
recordThreadResponse test-token U123 'Second reply' "$TS"
recordNotification test-token U123 "Second header" 'Other details'
recordThreadResponse test-token U123 'Other reply' "$TS"
printf '%s\\n%s\\n' "$first_report" "$TS"
''',
                    "test", str(REPOSITORY),
                ],
                cwd=directory,
                capture_output=True,
                text=True,
                timeout=10,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            paths = result.stdout.splitlines()
            self.assertEqual(len(paths), 2)
            reports = [json.loads((Path(directory) / path).read_text()) for path in paths]
            self.assertEqual(reports[0], {
                "header": "First header",
                "message": r"Details\nMore details",
                "replies": [r"First reply\nNext line", "Second reply"],
            })
            self.assertEqual(reports[1]["header"], "Second header")
            self.assertEqual(reports[1]["replies"], ["Other reply"])
            self.assertNotIn("test-token", json.dumps(reports))
            self.assertEqual(len(list((Path(directory) / "monitoring-reports").iterdir())), 2)


if __name__ == "__main__":
    unittest.main()