import subprocess
import unittest

from scripts.remove_direct_privileged_assignments import remove_direct_assignments


USER_ASSIGNMENT = {
    "accessType": "Direct",
    "principalType": "User",
    "assignmentId": (
        "/subscriptions/test-sub/providers/Microsoft.Authorization/"
        "roleAssignments/12345678-1234-1234-1234-123456789abc"
    ),
    "scope": "/subscriptions/test-sub",
    "upn": "user@example.com",
    "role": "Owner",
}


class RemoveDirectPrivilegedAssignmentsTests(unittest.TestCase):
    def test_removes_only_direct_user_assignments(self):
        calls = []

        def run(args, **kwargs):
            calls.append((args, kwargs))
            return subprocess.CompletedProcess(args, 0, "", "")

        group_assignment = {
            **USER_ASSIGNMENT,
            "accessType": "Via Group",
            "principalType": "Group",
        }
        malformed_group_assignment = {
            **USER_ASSIGNMENT,
            "principalType": "Group",
        }
        removed, failures = remove_direct_assignments(
            [USER_ASSIGNMENT, group_assignment, malformed_group_assignment], run=run
        )

        self.assertEqual(removed, {USER_ASSIGNMENT["assignmentId"]})
        self.assertEqual(failures, [])
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][0][0:4], [
            "az", "role", "assignment", "delete",
        ])
        self.assertIn(USER_ASSIGNMENT["assignmentId"], calls[0][0])

    def test_invalid_assignment_id_aborts_before_any_deletion(self):
        calls = []

        with self.assertRaisesRegex(ValueError, "invalid role-assignment ID"):
            remove_direct_assignments(
                [
                    USER_ASSIGNMENT,
                    {**USER_ASSIGNMENT, "assignmentId": "/subscriptions/other-sub/roleAssignments/bad"},
                ],
                run=lambda *args, **kwargs: calls.append(args),
            )

        self.assertEqual(calls, [])

    def test_reports_azure_cli_failures_without_claiming_removal(self):
        def run(args, **kwargs):
            return subprocess.CompletedProcess(args, 1, "", "AuthorizationFailed")

        removed, failures = remove_direct_assignments([USER_ASSIGNMENT], run=run)

        self.assertEqual(removed, set())
        self.assertEqual(failures, ["user@example.com (Owner): AuthorizationFailed"])

    def test_reports_timeout_as_failure(self):
        def run(args, **kwargs):
            raise subprocess.TimeoutExpired(args, 60)

        removed, failures = remove_direct_assignments([USER_ASSIGNMENT], run=run)

        self.assertEqual(removed, set())
        self.assertIn("user@example.com (Owner):", failures[0])


if __name__ == "__main__":
    unittest.main()
