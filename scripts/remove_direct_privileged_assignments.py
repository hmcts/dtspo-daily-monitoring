#!/usr/bin/env python3

import re
import subprocess


ROLE_ASSIGNMENT_ID = re.compile(
    r"/providers/Microsoft\.Authorization/roleAssignments/"
    r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
    re.IGNORECASE,
)


def remove_direct_assignments(candidates, run=subprocess.run):
    direct_candidates = [
        candidate for candidate in candidates
        if candidate.get("accessType") == "Direct"
        and candidate.get("principalType") == "User"
    ]

    for candidate in direct_candidates:
        assignment_id = candidate.get("assignmentId", "")
        scope = candidate.get("scope", "").rstrip("/")
        assignment_prefix = (
            scope + "/providers/Microsoft.Authorization/roleAssignments/"
        )
        if (
            not scope
            or not assignment_id.lower().startswith(assignment_prefix.lower())
            or not ROLE_ASSIGNMENT_ID.search(assignment_id)
        ):
            raise ValueError(
                "Refusing cleanup because a direct user assignment has an invalid "
                f"role-assignment ID: {candidate.get('upn', '<unknown user>')}"
            )

    removed_ids = set()
    failures = []
    for candidate in direct_candidates:
        assignment_id = candidate["assignmentId"]
        try:
            result = run(
                [
                    "az", "role", "assignment", "delete",
                    "--ids", assignment_id,
                    "--only-show-errors",
                    "--output", "none",
                ],
                capture_output=True,
                text=True,
                timeout=60,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            failures.append(
                f"{candidate.get('upn', '<unknown user>')} "
                f"({candidate.get('role', '<unknown role>')}): {error}"
            )
            continue

        if result.returncode == 0:
            removed_ids.add(assignment_id)
            print(
                "  Removed direct assignment: "
                f"{candidate.get('upn', '<unknown user>')} — "
                f"{candidate.get('role', '<unknown role>')} on {candidate['scope']}"
            )
        else:
            detail = (result.stderr or "").strip()
            failures.append(
                f"{candidate.get('upn', '<unknown user>')} "
                f"({candidate.get('role', '<unknown role>')}): "
                f"{detail or 'Azure CLI returned a non-zero exit code'}"
            )

    return removed_ids, failures
