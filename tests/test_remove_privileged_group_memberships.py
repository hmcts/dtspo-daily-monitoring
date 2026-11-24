import subprocess
import unittest

from scripts.remove_privileged_group_memberships import remove_group_memberships


MEMBERSHIP = {
    "groupId": "0A000000-0000-0000-0000-00000000000A",
    "groupName": "DTS Owners (mg:HMCTS)",
    "principalId": "B0B00000-0000-0000-0000-000000000001",
    "upn": "Bob.Smith@HMCTS.NET",
}


class RemovePrivilegedGroupMembershipsTests(unittest.TestCase):
    def test_removes_dts_owners_memberships_and_reports_failures(self):
        calls = []
        failing = {**MEMBERSHIP, "groupName": "DTS Owners (sub:dts-cftptl-intsvc)",
                   "principalId": "ca000000-0000-0000-0000-000000000005", "upn": "Carol@HMCTS.NET"}

        def run(args, **kwargs):
            calls.append(args)
            returncode = 1 if failing["principalId"] in args else 0
            return subprocess.CompletedProcess(args, returncode, "", "Insufficient privileges")

        removed, failures = remove_group_memberships([MEMBERSHIP, failing], run=run)

        self.assertEqual(calls[0], [
            "az", "ad", "group", "member", "remove",
            "--group", MEMBERSHIP["groupId"],
            "--member-id", MEMBERSHIP["principalId"],
            "--only-show-errors", "--output", "none",
        ])
        self.assertEqual(removed, {(MEMBERSHIP["groupId"].lower(), MEMBERSHIP["principalId"].lower())})
        self.assertEqual(failures, [
            "Carol@HMCTS.NET from DTS Owners (sub:dts-cftptl-intsvc): Insufficient privileges",
        ])

    def test_refuses_all_removals_when_any_membership_is_out_of_scope(self):
        for invalid in (
            {**MEMBERSHIP, "groupName": "DTS Contributors (mg:HMCTS)"},
            {**MEMBERSHIP, "groupName": "O365 Admin GA"},
            {**MEMBERSHIP, "principalId": "Bob.Smith@HMCTS.NET"},
            {**MEMBERSHIP, "groupId": ""},
        ):
            with self.subTest(invalid=invalid):
                calls = []

                with self.assertRaises(ValueError):
                    remove_group_memberships([MEMBERSHIP, invalid], run=lambda args, **_: calls.append(args))

                self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
