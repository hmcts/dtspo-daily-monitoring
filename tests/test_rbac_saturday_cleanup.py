import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]
SATURDAY_SCHEDULE = "Saturday morning daily checks and RBAC cleanup"

IDS = {
    "CRIME_SUB": "11111111-1111-1111-1111-111111111111",
    "CFT_SUB": "22222222-2222-2222-2222-222222222222",
    "SOC_SUB": "33333333-3333-3333-3333-333333333333",
    "OWNER": "8e3af657-a8ff-443c-a75c-2fe8c4bcb635",
    "O365_ADMIN_GA": "6ca4394a-463d-4782-82ea-e811739c01ca",
    "JANE": "7988d135-3f76-42a6-bc85-a2ef09ce593f",
    "BOB": "b0b00000-0000-0000-0000-000000000001",
    "B2CADMIN": "b2c00000-0000-0000-0000-000000000002",
    "SERVICE": "5e000000-0000-0000-0000-000000000003",
    "RECENT": "7e000000-0000-0000-0000-000000000004",
    "CAROL": "ca000000-0000-0000-0000-000000000005",
    "OWNERS_GROUP": "0a000000-0000-0000-0000-00000000000a",
    "CONTRIBUTORS_GROUP": "0c000000-0000-0000-0000-00000000000c",
    "NESTED_GROUP": "0e000000-0000-0000-0000-00000000000e",
}

FAKE_AZ = r'''
import json
import os
import sys

args = sys.argv[1:]
root = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(root, "az_calls.log"), "a") as log:
    log.write(json.dumps(args) + "\n")
globals().update(json.loads(os.environ["FAKE_AZ_IDS"]))

def arg(name):
    return args[args.index(name) + 1] if name in args else ""

def respond(value=None):
    if value is not None:
        print(json.dumps(value))
    sys.exit(0)

def fail():
    print("Forbidden", file=sys.stderr)
    sys.exit(1)

MANAGEMENT_GROUPS = {
    "CFT-Prod": "CFT - Production", "Crime": "Crime", "Heritage-Prod": "Heritage - Production",
    "Platform-Prod": "Platform - Production", "SDS-Prod": "SDS - Production",
    "SPS-Prod": "SPS - Production", "HMCTS": "HMCTS",
}
subscription = "Microsoft.Management/managementGroups/subscriptions"
DESCENDANTS = {
    "crime": [
        {"name": "Crime-Child", "type": "Microsoft.Management/managementGroups"},
        {"name": CRIME_SUB, "type": subscription},
    ],
    "cft-prod": [{"name": CFT_SUB, "type": subscription}],
    "hmcts": [
        {"name": "Crime", "type": "Microsoft.Management/managementGroups"},
        {"name": CRIME_SUB, "type": subscription},
        {"name": CFT_SUB, "type": subscription},
    ],
}

def owner(scope, assignment, principal, principal_type="User"):
    return {
        "assignmentId": f"{scope}/providers/Microsoft.Authorization/roleAssignments/{assignment}",
        "principalId": principal, "principalType": principal_type, "roleDefinitionName": "Owner",
        "roleDefinitionId": f"{scope}/providers/Microsoft.Authorization/roleDefinitions/{OWNER}",
        "scope": scope,
    }

HMCTS = "/providers/Microsoft.Management/managementGroups/HMCTS"
ASSIGNMENTS = {
    CRIME_SUB: [
        owner(f"/subscriptions/{CRIME_SUB}", "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", O365_ADMIN_GA),
        owner(f"/subscriptions/{CRIME_SUB}", "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", JANE),
        owner(HMCTS, "dddddddd-dddd-dddd-dddd-dddddddddddd", OWNERS_GROUP, "Group"),
        owner(HMCTS, "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee", CONTRIBUTORS_GROUP, "Group"),
    ],
    CFT_SUB: [owner(f"/subscriptions/{CFT_SUB}", "cccccccc-cccc-cccc-cccc-cccccccccccc", O365_ADMIN_GA)],
}
USERS = {
    O365_ADMIN_GA: {"upn": "hmctsdcd_outlook.com#EXT#@CJSCommonPlatform.onmicrosoft.com", "displayName": "O365 Admin GA"},
    JANE: {"upn": "Jane.Doe@HMCTS.NET", "displayName": "Jane Doe"},
}
GROUPS = {
    OWNERS_GROUP: "DTS Owners (mg:HMCTS)",
    CONTRIBUTORS_GROUP: "DTS Contributors (mg:HMCTS)",
}

def user(object_id, upn):
    return {"@odata.type": "#microsoft.graph.user", "id": object_id, "userPrincipalName": upn, "displayName": upn}

MEMBERS = {
    OWNERS_GROUP: [
        user(BOB, "Bob.Smith@HMCTS.NET"),
        user(B2CADMIN, "b2cadmin@hmcts.net"),
        user(O365_ADMIN_GA, "hmctsdcd_outlook.com#EXT#@CJSCommonPlatform.onmicrosoft.com"),
        user(SERVICE, "dts-automation@HMCTS.NET"),
        user(RECENT, "Recent.User@HMCTS.NET"),
        {"@odata.type": "#microsoft.graph.group", "id": NESTED_GROUP, "displayName": "Nested"},
    ],
    CONTRIBUTORS_GROUP: [user(CAROL, "Carol.Jones@HMCTS.NET")],
}

if args[:3] == ["role", "definition", "list"]:
    respond([{"id": OWNER, "roleName": "Owner", "roleType": "BuiltInRole", "actions": ["*"]}])
if args[:1] == ["rest"]:
    uri = arg("--uri") or arg("--url")
    if "/managementGroups?" in uri:
        respond({"value": [{"name": k, "properties": {"displayName": v}} for k, v in MANAGEMENT_GROUPS.items()]})
    if "/descendants?" in uri:
        mg = uri.split("/managementGroups/")[1].split("/")[0].lower()
        if mg in os.environ.get("FAIL_DESCENDANTS", "").split(","):
            fail()
        respond({"value": DESCENDANTS.get(mg, [])})
    if "directoryAudits" in uri:
        if os.environ.get("FAIL_AUDIT"):
            fail()
        if uri.endswith("audit-page-2"):
            respond({"value": [{"targetResources": [
                {"type": "Group", "id": OWNERS_GROUP}, {"type": "User", "id": RECENT},
            ]}]})
        respond({"value": [], "@odata.nextLink": "https://graph.microsoft.com/directoryAudits/audit-page-2"})
if args[:2] == ["account", "list"]:
    if "HMCTS-SOC-PROD" in arg("--query"):
        respond([SOC_SUB])
    respond([{"id": s, "name": n} for s, n in ((CRIME_SUB, "Crime Prod"), (CFT_SUB, "CFT Prod"), (SOC_SUB, "HMCTS-SOC-PROD"))])
if args[:3] == ["role", "assignment", "list"]:
    respond([] if "--scope" in args else ASSIGNMENTS.get(arg("--subscription"), []))
if args[:3] == ["ad", "user", "show"]:
    respond(USERS[arg("--id")])
if args[:3] == ["ad", "group", "show"]:
    respond({"displayName": GROUPS[arg("--group")]})
if args[:4] == ["ad", "group", "member", "list"]:
    respond(MEMBERS[arg("--group")])
if args[:3] == ["role", "assignment", "delete"] or args[:4] == ["ad", "group", "member", "remove"]:
    respond()
print(f"Unexpected az call: {args}", file=sys.stderr)
sys.exit(2)
'''

EXCEPTIONS = f"""excluded_subscriptions:

group_cleanup_exempt_principals:
  - {IDS["O365_ADMIN_GA"]}

allowed_assignments:
  - principal_name: hmctsdcd_outlook.com#EXT#
    role: Owner
    scope: /providers/Microsoft.Management/managementGroups/Crime
    comment: O365 Admin GA
  - principal_name: b2cadmin
    role: Owner
    scope: /providers/Microsoft.Management/managementGroups/HMCTS
    comment: GA account
"""


class SaturdayCleanupTests(unittest.TestCase):
    def run_audit(self, schedule=SATURDAY_SCHEDULE, **failures):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts = root / "scripts"
            scripts.mkdir()
            for name in (
                "rbac-privileged-role-audit.sh",
                "rbac_exception_scopes.py",
                "remove_direct_privileged_assignments.py",
                "remove_privileged_group_memberships.py",
            ):
                shutil.copyfile(REPOSITORY / "scripts" / name, scripts / name)
            (scripts / "prod_audit_exceptions.yaml").write_text(EXCEPTIONS)
            (scripts / "common-functions.sh").write_text(
                'recordNotification() { printf "%s\\n%s\\n" "$3" "$4" >> report.txt; TS=report.txt; }\n'
                'recordThreadResponse() { printf "%s\\n" "$3" >> "$4"; }\n'
            )
            az = root / "az"
            az.write_text(f"#!{sys.executable}\n{FAKE_AZ}")
            getopt = root / "getopt"
            getopt.write_text(
                f"#!{sys.executable}\n"
                "import shlex, sys\n"
                'print(shlex.join(sys.argv[sys.argv.index("--") + 1:] + ["--"]))\n'
            )
            for executable in (az, getopt):
                executable.chmod(0o755)
            result = subprocess.run(
                [
                    "bash", "scripts/rbac-privileged-role-audit.sh",
                    "--slackBotToken", "test-token",
                    "--slackChannelName", "test-channel",
                    "--remove-direct",
                ],
                cwd=root,
                env={
                    **os.environ,
                    "PATH": f"{root}:{os.environ['PATH']}",
                    "BUILD_REASON": "Schedule",
                    "BUILD_SOURCEBRANCH": "refs/heads/master",
                    "BUILD_CRONSCHEDULE_DISPLAYNAME": schedule,
                    "FAIL_DESCENDANTS": failures.get("descendants", ""),
                    "FAIL_AUDIT": failures.get("audit", ""),
                    "FAKE_AZ_IDS": json.dumps(IDS),
                },
                capture_output=True,
                text=True,
                timeout=60,
            )
            calls = [json.loads(line) for line in (root / "az_calls.log").read_text().splitlines()]
            deleted = {
                call[call.index("--ids") + 1].rsplit("/", 1)[1]
                for call in calls
                if call[:3] == ["role", "assignment", "delete"]
            }
            removed = {
                (call[call.index("--group") + 1], call[call.index("--member-id") + 1])
                for call in calls
                if call[:4] == ["ad", "group", "member", "remove"]
            }
            report_file = root / "report.txt"
            report = report_file.read_text() if report_file.exists() else ""
            return result, deleted, removed, report

    def test_saturday_cleanup_removes_direct_access_and_dts_owners_members(self):
        result, deleted, removed, report = self.run_audit()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(deleted, {
            "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",  # Unapproved user under Crime
            "cccccccc-cccc-cccc-cccc-cccccccccccc",  # O365 Admin GA outside its Crime exception
        })
        # O365 Admin GA is exempt; allowed_assignments (b2cadmin) do not prevent removal;
        # service accounts, nested groups, recent additions and non-Owners groups are kept.
        self.assertEqual(removed, {
            (IDS["OWNERS_GROUP"], IDS["BOB"]),
            (IDS["OWNERS_GROUP"], IDS["B2CADMIN"]),
        })
        self.assertIn(
            "Removed 2 unapproved direct user assignment(s) and 2 DTS Owners group membership(s)",
            report,
        )
        self.assertIn("Carol.Jones@HMCTS.NET", report)
        self.assertNotIn("Bob.Smith@HMCTS.NET", report)

    def test_cleanup_aborts_before_changes_when_inputs_are_incomplete(self):
        for failure in ({"descendants": "hmcts"}, {"audit": "1"}):
            with self.subTest(**failure):
                result, deleted, removed, _ = self.run_audit(**failure)

                self.assertNotEqual(result.returncode, 0)
                self.assertIn("aborted", result.stdout + result.stderr)
                self.assertEqual((deleted, removed), (set(), set()))

    def test_audit_only_run_changes_nothing_and_tolerates_lookup_failures(self):
        result, deleted, removed, report = self.run_audit(
            schedule="Runs 8 AM & 3 PM Mon-Fri", descendants="hmcts", audit="1"
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("WARNING: Could not resolve management-group exception scopes", result.stdout)
        self.assertEqual((deleted, removed), (set(), set()))
        self.assertIn("Bob.Smith@HMCTS.NET", report)


if __name__ == "__main__":
    unittest.main()
