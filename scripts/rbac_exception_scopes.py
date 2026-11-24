#!/usr/bin/env python3

import json
import re
import subprocess


MANAGEMENT_GROUP_SCOPE = re.compile(
    r"^/providers/microsoft\.management/managementgroups/([^/]+)$",
    re.IGNORECASE,
)
DESCENDANTS_URI = (
    "https://management.azure.com/providers/Microsoft.Management/"
    "managementGroups/{}/descendants?api-version=2020-05-01&%24top=1000"
)


def management_group_id(scope):
    match = MANAGEMENT_GROUP_SCOPE.match((scope or "").rstrip("/"))
    return match.group(1) if match else None


def load_management_group_descendants(scopes, run=subprocess.run):
    """Return {lowercase management group ID: lowercase descendant subscription and management-group scopes}."""
    mg_ids = {}
    for scope in scopes:
        mg_id = management_group_id(scope)
        if mg_id:
            mg_ids.setdefault(mg_id.lower(), mg_id)

    descendants = {}
    for key, mg_id in sorted(mg_ids.items()):
        children = set()
        uri = DESCENDANTS_URI.format(mg_id)
        while uri:
            result = run(
                ["az", "rest", "--method", "GET", "--uri", uri, "-o", "json"],
                capture_output=True,
                text=True,
                timeout=60,
            )
            if result.returncode != 0:
                raise RuntimeError(
                    f"descendants of management group '{mg_id}' could not be enumerated: "
                    f"{(result.stderr or '').strip()[:300]}"
                )
            data = json.loads(result.stdout)
            for item in data.get("value", []):
                item_type = (item.get("type") or "").lower()
                name = (item.get("name") or "").lower()
                if not name:
                    continue
                if item_type == "microsoft.management/managementgroups/subscriptions":
                    children.add(f"/subscriptions/{name}")
                elif item_type == "microsoft.management/managementgroups":
                    children.add(f"/providers/microsoft.management/managementgroups/{name}")
            uri = data.get("nextLink")
        descendants[key] = children
    return descendants


def exception_scope_matches(exception_scope, scope, descendants):
    exception_scope = (exception_scope or "").lower().rstrip("/")
    scope = (scope or "").lower().rstrip("/")
    if scope.startswith(exception_scope):
        return True
    mg_id = management_group_id(exception_scope)
    if not mg_id:
        return False
    return any(
        scope == child or scope.startswith(child + "/")
        for child in descendants.get(mg_id, ())
    )
