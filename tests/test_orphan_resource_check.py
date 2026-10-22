import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]
PREFIX = "/subscriptions/test-sub/resourceGroups/test-rg/providers/Test/items/"


class OrphanResourceCheckTests(unittest.TestCase):
    def run_check(self, names=(), body=None, download_fails=False, slack_fails=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts = root / "scripts"
            scripts.mkdir()
            for name in (
                "orphan-resource-check.sh",
                "reconcile-orphan-resources.sh",
                "common-functions.sh",
                "header-block-template.json",
            ):
                shutil.copyfile(REPOSITORY / "scripts" / name, scripts / name)
            fixtures = root / "source.json"
            if body is None:
                body = json.dumps([
                    {"message": f"az resource delete --ids {PREFIX}{name} --verbose"}
                    for name in names
                ])
            fixtures.write_text(body)
            curl = root / "curl"
            curl.write_text(
                f"#!{sys.executable}\n"
                """import json, os, sys
from pathlib import Path
args = sys.argv[1:]
if args[-1] == "https://slack.com/api/chat.postMessage":
    payload = json.loads(args[args.index("--data") + 1])
    with open(os.environ["SLACK_CALLS"], "a") as output:
        output.write(json.dumps(payload) + "\\n")
    print(json.dumps({"ok": os.environ["SLACK_FAILS"] != "1", "ts": "123.456", "error": "mock_failure"}))
elif args[-1].startswith("https://raw.githubusercontent.com/"):
    if os.environ["DOWNLOAD_FAILS"] == "1":
        print("HTTP 503", file=sys.stderr)
        sys.exit(22)
    print(Path(os.environ["SOURCE"]).read_text())
else:
    sys.exit("Unexpected network request")
"""
            )
            az = root / "az"
            az.write_text(
                """#!/usr/bin/env bash
set -eu
[[ $# -eq 7 || $# -eq 9 ]] || exit 99
[[ "$1" == resource && "$2" == show && "$3" == --ids &&
   "$5" == --output && "$6" == json && "$7" == --only-show-errors ]] || exit 99
version=
[[ $# -eq 7 ]] || { [[ "$8" == --api-version ]] || exit 99; version=$9; }
printf '%s\\n' "$4" >> "$AZ_CALLS"
case "${4##*/}" in
    present) printf '{"id":"%s"}\\n' "$4" ;;
    absent) echo 'ERROR: (ResourceNotFound) Resource not found.' >&2; exit 3 ;;
    regional)
        if [[ -z "$version" ]]; then
            echo "ERROR: (NoRegisteredProviderFound) No provider. The supported api-versions are '2025-05-01, 2026-03-01'." >&2
            exit 1
        fi
        printf '{"id":"%s"}\\n' "$4" ;;
    noisy)
        echo 'SyntaxWarning: noisy library warning' >&2
        printf 'ERROR: (Failure) %s\\nMessage: second line\\n' "$(printf 'x%.0s' {1..500})" >&2
        exit 1 ;;
    *) printf 'ERROR: (AuthorizationFailed) Access "denied".\\nCheck permissions.\\n' >&2; exit 1 ;;
esac
"""
            )
            uname = root / "uname"
            uname.write_text("#!/bin/sh\nprintf 'Linux\\n'\n")
            for executable in (curl, az, uname):
                executable.chmod(0o755)
            slack_calls = root / "slack.jsonl"
            az_calls = root / "az.txt"
            result = subprocess.run(
                [
                    "bash", "scripts/orphan-resource-check.sh",
                    "--slackBotToken", "test-token", "--slackChannelName", "test-channel",
                ],
                cwd=root,
                env={
                    **os.environ,
                    "PATH": f"{root}:{os.environ['PATH']}",
                    "SOURCE": str(fixtures),
                    "SLACK_CALLS": str(slack_calls),
                    "AZ_CALLS": str(az_calls),
                    "DOWNLOAD_FAILS": str(int(download_fails)),
                    "SLACK_FAILS": str(int(slack_fails)),
                },
                capture_output=True,
                text=True,
                timeout=30,
            )
            posts = [json.loads(line) for line in slack_calls.read_text().splitlines()] if slack_calls.exists() else []
            calls = az_calls.read_text().splitlines() if az_calls.exists() else []
            self.assertEqual(fixtures.read_text(), body)
            return result, posts, calls

    def test_only_existing_resources_appear_in_historical_failure_thread(self):
        result, posts, calls = self.run_check(["present", "absent", "present"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 3)
        self.assertEqual(len(posts), 2)
        self.assertIn("Historical cleanup failures — still exists", posts[0]["blocks"][0]["text"]["text"])
        self.assertIn("2 still exist; 1 confirmed not found; 0 could not be verified", posts[0]["blocks"][1]["text"]["text"])
        self.assertIn("(UTC)", posts[0]["blocks"][1]["text"]["text"])
        self.assertEqual(posts[1]["text"], "\n".join([":red_circle: " + PREFIX + "present"] * 2))
        self.assertEqual(posts[1]["thread_ts"], "123.456")
        self.assertNotIn(PREFIX + "absent", json.dumps(posts))

    def test_verification_errors_are_separate_and_fail_the_check(self):
        result, posts, calls = self.run_check(["present", "absent", "forbidden"])
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(len(calls), 3)
        self.assertEqual(len(posts), 4)
        self.assertIn("Historical cleanup verification errors", posts[2]["blocks"][0]["text"]["text"])
        self.assertIn("must not be treated as deleted", posts[2]["blocks"][1]["text"]["text"])
        self.assertEqual(posts[1]["text"], ":red_circle: " + PREFIX + "present")
        self.assertIn(PREFIX + "forbidden", posts[3]["text"])
        self.assertIn('ERROR: (AuthorizationFailed) Access "denied".', posts[3]["text"])
        self.assertNotIn("Check permissions", posts[3]["text"])
        self.assertNotIn(PREFIX + "absent", json.dumps(posts))

    def test_region_specific_api_version_error_is_retried_not_reported(self):
        result, posts, calls = self.run_check(["regional"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(posts), 2)
        self.assertIn("1 still exist; 0 confirmed not found; 0 could not be verified", posts[0]["blocks"][1]["text"]["text"])
        self.assertEqual(posts[1]["text"], ":red_circle: " + PREFIX + "regional")
        self.assertEqual(len(calls), 2)

    def test_slack_error_detail_is_first_error_line_and_bounded(self):
        result, posts, _ = self.run_check(["noisy"])
        self.assertEqual(result.returncode, 1)
        reply = posts[1]["text"]
        self.assertIn("ERROR: (Failure) xxx", reply)
        self.assertNotIn("SyntaxWarning", reply)
        self.assertNotIn("second line", reply)
        self.assertLessEqual(len(reply.split("\n", 1)[1]), 300)

    def test_no_alert_when_all_missing_or_empty(self):
        for names in (["absent"], []):
            with self.subTest(names=names):
                result, posts, _ = self.run_check(names)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(posts, [])

    def test_all_inaccessible_resources_are_reported_as_errors(self):
        result, posts, _ = self.run_check(["forbidden"])
        self.assertEqual(result.returncode, 1)
        self.assertEqual(len(posts), 2)
        self.assertIn("verification errors", posts[0]["blocks"][0]["text"]["text"])
        self.assertIn("0 still exist; 0 confirmed not found; 1 could not be verified", posts[0]["blocks"][1]["text"]["text"])

    def test_bad_input_and_download_failures_alert_without_azure_calls(self):
        scenarios = [
            {"download_fails": True},
            {"body": "invalid JSON"},
            {"body": "{}"},
            {"body": '[{"message": "no resource ID"}]'},
        ]
        for scenario in scenarios:
            with self.subTest(scenario=scenario):
                result, posts, calls = self.run_check(**scenario)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(calls, [])
                self.assertEqual(len(posts), 1)
                self.assertIn("verification errors", posts[0]["blocks"][0]["text"]["text"])

    def test_managed_aks_nsg_exclusions_are_preserved(self):
        message = (
            "az resource delete --ids /subscriptions/test/resourceGroups/test-aks-node-rg/"
            "providers/Microsoft.Network/networkSecurityGroups/aks-appgateway-test-nsg --verbose"
        )
        result, posts, calls = self.run_check(body=json.dumps([{"message": message}]))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(posts, [])
        self.assertEqual(calls, [])

    def test_slack_failure_is_not_silently_ignored(self):
        result, _, _ = self.run_check(["present"], slack_fails=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Slack post failed", result.stderr)


if __name__ == "__main__":
    unittest.main()
