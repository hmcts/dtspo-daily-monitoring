#!/usr/bin/env python3

import re
import subprocess


DTS_OWNERS_GROUP = re.compile(r"^DTS Owners \((mg|sub):", re.IGNORECASE)
OBJECT_ID = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
    re.IGNORECASE,
)


def is_dts_owners_group(group_name):
    return bool(DTS_OWNERS_GROUP.match(group_name or ""))


def validate_group_memberships(candidates):
    for candidate in candidates:
        if (
            not candidate.get("groupName")
            or not OBJECT_ID.match(candidate.get("groupId") or "")
            or not OBJECT_ID.match(candidate.get("principalId") or "")
        ):
            raise ValueError(
                "Refusing cleanup because a group membership is not a valid "
                f"user membership: {candidate.get('upn', '<unknown user>')} in "
                f"{candidate.get('groupName', '<unknown group>')}"
            )


def remove_group_memberships(candidates, run=subprocess.run):
    """Remove users from groups; returns ({(group ID, user ID)}, failures)."""
    validate_group_memberships(candidates)

    removed = set()
    failures = []
    for candidate in candidates:
        label = f"{candidate.get('upn', '<unknown user>')} from {candidate['groupName']}"
        try:
            result = run(
                [
                    "az", "ad", "group", "member", "remove",
                    "--group", candidate["groupId"],
                    "--member-id", candidate["principalId"],
                    "--only-show-errors",
                    "--output", "none",
                ],
                capture_output=True,
                text=True,
                timeout=60,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            failures.append(f"{label}: {error}")
            continue

        if result.returncode == 0:
            removed.add((candidate["groupId"].lower(), candidate["principalId"].lower()))
            print(f"  Removed group membership: {label}")
        else:
            detail = (result.stderr or "").strip()
            failures.append(f"{label}: {detail or 'Azure CLI returned a non-zero exit code'}")

    return removed, failures
