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
    def run_sender(self, reports, ready=True, slack_fails=False, partial_write=False, rejected_text="", echo_escapes=False):
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
            if partial_write:
                (report_directory / ".reply-interrupted").write_text('{"header": "unfinished\n')
            for index, report in enumerate(reports):
                content = report if isinstance(report, str) else json.dumps(report)
                (report_directory / f"report-{index:04d}").write_text(content)
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
empty_reply = "text" in payload and not payload["text"].strip()
rejected_reply = bool(os.environ["REJECTED_TEXT"]) and payload.get("text") == os.environ["REJECTED_TEXT"]
print(json.dumps({"ok": os.environ["SLACK_FAILS"] != "1" and not empty_reply and not rejected_reply, "ts": f"100.{count}", "message": payload, "error": "no_text" if empty_reply else "mock_failure"}))
'''
            )
            curl.chmod(0o755)
            uname = root / "uname"
            uname.write_text("#!/bin/sh\nprintf 'Linux\\n'\n")
            uname.chmod(0o755)
            calls = root / "calls.jsonl"
            bash_environment = root / "bash-environment"
            bash_environment.write_text("shopt -s xpg_echo\n" if echo_escapes else "")
            result = subprocess.run(
                ["bash", "scripts/send-monitoring-reports.sh", str(report_directory), "test-token", "U123"],
                cwd=root,
                env={
                    **os.environ,
                    "PATH": f"{root}:{os.environ['PATH']}",
                    "SLACK_CALLS": str(calls),
                    "SLACK_FAILS": str(int(slack_fails)),
                    "REJECTED_TEXT": rejected_text,
                    "BASH_ENV": str(bash_environment),
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

    def test_jira_details_send_when_slack_echoes_multiline_json(self):
        result, posts = self.run_sender([
            {"header": "Jira Status", "message": "BAU tickets\nStatus summary", "replies": [
                ":red_circle: *95* Open BAU issues\n:yellow_circle: *12* Unassigned issues",
            ]},
            {"header": "Jira Ticket Status", "message": "4 issues closed yesterday", "replies": [
                "Closed issues:\n>_First User_: 3\n>_Second User_: 1",
                "Currently assigned:\n>_First User_: 12",
            ]},
        ])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(posts), 5)
        self.assertIn("95", posts[1]["text"])
        self.assertEqual(posts[1]["thread_ts"], "100.0")
        self.assertIn(">_First User_: 3", posts[3]["text"])
        self.assertIn(">_First User_: 12", posts[4]["text"])
        self.assertEqual(posts[3]["thread_ts"], "100.2")
        self.assertEqual(posts[4]["thread_ts"], "100.2")
        self.assertIn("Jira Status (1 saved replies)", result.stderr)
        self.assertIn("Jira Ticket Status (2 saved replies)", result.stderr)

    def test_slack_response_json_is_not_reinterpreted_by_echo(self):
        result, posts = self.run_sender([
            {"header": ":red_circle: Jira Status", "message": "BAU tickets\nStatus summary", "replies": [
                "95 open issues\n12 unassigned issues",
            ]},
        ], echo_escapes=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(posts), 2)
        self.assertEqual(posts[1]["text"], "95 open issues\n12 unassigned issues")
        self.assertEqual(posts[1]["thread_ts"], "100.0")

    def test_sends_reports_alphabetically_ignoring_status_icons_and_case(self):
        result, posts = self.run_sender([
            {"header": ":red_circle: :jenkins: Jenkins Status", "message": "Details", "replies": ["Jenkins reply"]},
            {"header": ":yellow_circle: Certificate checks", "message": "Details", "replies": []},
            {"header": ":red_circle: GitHub actions", "message": "Details", "replies": []},
            {"header": ":yellow_circle: :clock1: Auto Shutdown Status", "message": "Details", "replies": ["Auto reply"]},
            {"header": ":red_circle: azure DevOps pipelines", "message": "Details", "replies": []},
        ])
        self.assertEqual(result.returncode, 0, result.stderr)
        headers = [post["blocks"][0]["text"]["text"] for post in posts if "blocks" in post]
        self.assertEqual(headers, [
            ":yellow_circle: :clock1: Auto Shutdown Status",
            ":red_circle: azure DevOps pipelines",
            ":yellow_circle: Certificate checks",
            ":red_circle: GitHub actions",
            ":red_circle: :jenkins: Jenkins Status",
        ])
        self.assertEqual(posts[1]["text"], "Auto reply")
        self.assertEqual(posts[1]["thread_ts"], "100.0")
        self.assertEqual(posts[-1]["text"], "Jenkins reply")
        self.assertEqual(posts[-1]["thread_ts"], "100.5")

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

    def test_empty_jira_replies_are_skipped_and_later_reports_are_sent(self):
        result, posts = self.run_sender([
            {"header": "Jira Ticket Status", "message": "0 issues closed yesterday", "replies": [
                "0 issues closed yesterday:", "", "Current assigned tickets", " \n\t", r"\n",
            ]},
            {"header": "PostgreSQL checks", "message": "Storage details", "replies": ["Storage reply"]},
        ])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([post["text"] for post in posts if "text" in post], [
            "0 issues closed yesterday:", "Current assigned tickets", "Storage reply",
        ])
        self.assertEqual(posts[-2]["blocks"][0]["text"]["text"], "PostgreSQL checks")

    def test_reply_failure_does_not_stop_later_replies_or_reports(self):
        result, posts = self.run_sender([
            {"header": "Jira Status", "message": "Details", "replies": ["Rejected reply", "Next Jira reply"]},
            {"header": "PostgreSQL checks", "message": "Storage details", "replies": ["Storage reply"]},
        ], rejected_text="Rejected reply")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(len(posts), 5)
        self.assertEqual(posts[2]["text"], "Next Jira reply")
        self.assertEqual(posts[2]["thread_ts"], "100.0")
        self.assertEqual(posts[-1]["text"], "Storage reply")
        self.assertIn("Jira Status", result.stderr)

    def test_truncated_report_identifies_the_file_before_posting(self):
        result, posts = self.run_sender([
            {"header": "Valid", "message": "Details", "replies": []},
            '{"header": "unfinished\n',
        ])
        self.assertEqual(result.returncode, 1)
        self.assertEqual(posts, [])
        self.assertIn("Invalid monitoring report:", result.stderr)
        self.assertIn("report-0001", result.stderr)

    def test_interrupted_temporary_write_is_not_sent(self):
        result, posts = self.run_sender([
            {"header": "Valid", "message": "Details", "replies": []},
        ], partial_write=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(posts), 1)
        self.assertEqual(posts[0]["blocks"][0]["text"]["text"], "Valid")

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