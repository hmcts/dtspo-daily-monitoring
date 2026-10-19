import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/reconcile-orphan-resources.sh"
RESOURCE_PREFIX = "/subscriptions/test-sub/resourceGroups/test-rg"


class ReconcileOrphanResourcesTests(unittest.TestCase):
    def run_check(self, names=None, records=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            az = root / "az"
            az.write_text(
                """#!/usr/bin/env bash
set -eu
[[ $# -eq 7 && "$1" == resource && "$2" == show && "$3" == --ids &&
   "$5" == --output && "$6" == json && "$7" == --only-show-errors ]] || exit 99
printf '%s\\n' "$4" >> "$AZ_CALLS"
case "${4##*/}" in
    present) printf '{"id":"%s"}\\n' "$4" ;;
    absent) echo 'ERROR: (ResourceNotFound) Resource not found.' >&2; exit 3 ;;
    missing-rg) echo 'ERROR: (ResourceGroupNotFound) Resource group not found.' >&2; exit 3 ;;
    forbidden) echo 'ERROR: (AuthorizationFailed) Access denied.' >&2; exit 1 ;;
    subscription) echo 'ERROR: (SubscriptionNotFound) Subscription unavailable.' >&2; exit 1 ;;
    login) echo "ERROR: Please run az login." >&2; exit 1 ;;
    timeout) echo 'ERROR: Connection timed out.' >&2; exit 1 ;;
    empty) exit 0 ;;
    invalid) echo 'not json' ;;
    wrong-id) echo '{"id":"/subscriptions/another/resourceGroups/another"}' ;;
    *) echo 'Unexpected test request.' >&2; exit 99 ;;
esac
"""
            )
            az.chmod(0o755)
            source = root / "status.json"
            if records is None:
                records = [
                    {
                        "message": (
                            "A resource failed to delete!\\nTo see why, you can run: "
                            f"az resource delete --ids {RESOURCE_PREFIX}/providers/Test/items/{name} "
                            "--verbose\\n"
                        )
                    }
                    for name in names
                ]
            source.write_text(json.dumps(records))
            original = source.read_bytes()
            calls = root / "calls.txt"
            result = subprocess.run(
                ["bash", str(SCRIPT), str(source)],
                env={**os.environ, "PATH": f"{root}:{os.environ['PATH']}", "AZ_CALLS": str(calls)},
                capture_output=True,
                text=True,
                timeout=30,
            )
            self.assertEqual(source.read_bytes(), original)
            actual_calls = calls.read_text().splitlines() if calls.exists() else []
            return result, actual_calls

    def test_existing_and_confirmed_absent_resources(self):
        result, calls = self.run_check(["present", "absent", "missing-rg"])
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["summary"], {"exists": 1, "notFound": 2, "unverified": 0})
        self.assertEqual(len(calls), 3)
        self.assertRegex(report["checkedAt"], r"^\d{4}-\d{2}-\d{2}T.*Z$")
        self.assertEqual(report["resources"][0]["status"], "exists")
        self.assertIn("ResourceNotFound", report["resources"][1]["detail"])

    def test_errors_and_invalid_successes_are_never_classified_as_absent(self):
        names = ["forbidden", "subscription", "login", "timeout", "empty", "invalid", "wrong-id"]
        result, calls = self.run_check(names)
        self.assertEqual(result.returncode, 1)
        report = json.loads(result.stdout)
        self.assertEqual(report["summary"], {"exists": 0, "notFound": 0, "unverified": len(names)})
        self.assertEqual(len(calls), len(names))
        self.assertTrue(all(item["detail"] for item in report["resources"]))
        self.assertIn("could not be verified", result.stderr)

    def test_empty_list(self):
        result, calls = self.run_check([])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["resources"], [])
        self.assertEqual(calls, [])

    def test_malformed_records_fail_before_azure_requests(self):
        for records in ({}, [None], [{}], [{"message": "unexpected"}], [{"message": 42}]):
            with self.subTest(records=records):
                result, calls = self.run_check(records=records)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertEqual(calls, [])
                self.assertIn("error", result.stderr)

    def test_partial_results_are_retained_when_one_check_fails(self):
        result, calls = self.run_check(["present", "forbidden", "absent"])
        self.assertEqual(result.returncode, 1)
        self.assertEqual(
            json.loads(result.stdout)["summary"],
            {"exists": 1, "notFound": 1, "unverified": 1},
        )
        self.assertEqual(len(calls), 3)


if __name__ == "__main__":
    unittest.main()
