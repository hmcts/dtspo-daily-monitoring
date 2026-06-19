#!/usr/bin/env bash

# Compare two privileged-RBAC snapshot CSVs (produced by audit-privileged-rbac.sh)
# and write a Slack-ready report of what changed between them.
#
# The report file uses the same :red_circle: / :yellow_circle: convention as the
# other monitors, so it can be handed straight to send-slack-header-thread-each-loop.sh
# (which only notifies when one of those markers is present).
#
# Change classification (key = PrincipalId | RoleDefinitionId | Scope):
#   :red_circle:    new Permanent privileged assignment, any added Owner /
#                   User Access Administrator, or Temporary -> Permanent elevation
#   :yellow_circle: other added / removed / changed assignments
#   :white_check_mark: allowlisted principal self-adding / self-elevating
#                   (informational only; never triggers a notification on its own)
#


### Setup script environment
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

currentFile=""
currentDir=""
baselineFile=""
baselineDir=""
outputFile="rbac-change-status.txt"
windowDays="2"
allowlistFile="${SCRIPT_DIR}/allowlist.txt"

usage() {
>&2 cat << EOF
    ------------------------------------------------
    Detect privileged RBAC changes between two snapshots
    ------------------------------------------------
    Usage: $0
        [ --currentFile <path> | --currentDir <dir> ]    # today's snapshot CSV (or dir to glob)
        [ --baselineFile <path> | --baselineDir <dir> ]  # prior snapshot CSV (or dir to glob)
        [ -o | --outputFile <path> ]                     # report file (default: rbac-change-status.txt)
        [ -w | --windowDays <n> ]                        # window size, for the message text (default: 2)
        [ -a | --allowlistFile <path> ]                  # principals allowed to self-add (default: <script dir>/allowlist.txt)
        [ -h | --help ]
EOF
exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --currentFile)  currentFile="$2";  shift 2 ;;
        --currentDir)   currentDir="$2";   shift 2 ;;
        --baselineFile) baselineFile="$2"; shift 2 ;;
        --baselineDir)  baselineDir="$2";  shift 2 ;;
        -o|--outputFile) outputFile="$2";  shift 2 ;;
        -w|--windowDays) windowDays="$2";  shift 2 ;;
        -a|--allowlistFile) allowlistFile="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1" >&2; usage ;;
    esac
done

# Resolve a snapshot path from an explicit file or by globbing the newest
# rbac-snapshot-*.csv in a directory (ISO date names sort chronologically).
resolve_csv() {
    local file="$1" dir="$2" match=""
    if [[ -n "$file" ]]; then
        printf '%s' "$file"
        return 0
    fi
    if [[ -n "$dir" ]]; then
        match=$(ls -1 "$dir"/rbac-snapshot-*.csv 2>/dev/null | LC_ALL=C sort | tail -n 1 || true)
        printf '%s' "$match"
    fi
    return 0
}

CURRENT_CSV="$(resolve_csv "$currentFile" "$currentDir")"
BASELINE_CSV="$(resolve_csv "$baselineFile" "$baselineDir")"

# Always create the report file so the downstream sender's `cat` never fails.
: > "$outputFile"

if [[ -z "$CURRENT_CSV" || ! -f "$CURRENT_CSV" ]]; then
    echo "Error: current snapshot not found (currentFile='$currentFile' currentDir='$currentDir')" >&2
    exit 1
fi

if [[ -z "$BASELINE_CSV" || ! -f "$BASELINE_CSV" ]]; then
    echo "Permission failure/ or No baseline snapshot available; skipping change detection (no notification will be sent)."
    exit 0
fi

echo "Comparing privileged RBAC snapshots over a ${windowDays}-day window:"
echo "  baseline: $BASELINE_CSV"
echo "  current:  $CURRENT_CSV"
if [[ -f "$allowlistFile" ]]; then
    echo "  allowlist: $allowlistFile"
else
    echo "  allowlist: (none found at $allowlistFile)"
fi

# The CSV is quoted (fields may contain commas), so parse it with Python's csv
# module rather than awk. Emit Slack-ready lines to the report file.
CURRENT_CSV="$CURRENT_CSV" BASELINE_CSV="$BASELINE_CSV" ALLOWLIST_FILE="$allowlistFile" python3 - >> "$outputFile" <<'PY'
import csv
import os

RED_ROLES = {
    "Owner",
    "Contributor",
    "Access Review Operator Service Role",
    "Anyscale Platform Administrator Role",
    "Azure Contributor Role minus deletes",
    "PIM Azure Contributor",
    "Reservations Administrator",
    "Role Based Access Control Administrator",
    "Service Group Administrator",
    "Service Group Contributor",
    "User Access Administrator",
}


def load(path):
    rows = {}
    with open(path, newline="", encoding="utf-8") as fh:
        for r in csv.DictReader(fh):
            key = (
                r.get("PrincipalId", ""),
                r.get("RoleDefinitionId", ""),
                r.get("Scope", ""),
            )
            rows[key] = r
    return rows


def load_allowlist(path):
    # Match on object ID (PrincipalId) or UPN (Identifier) only; never on the
    # mutable DisplayName. Lines starting with '#' and blank lines are ignored.
    entries = set()
    if not path or not os.path.isfile(path):
        return entries
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            token = line.split("#", 1)[0].strip()
            if token:
                entries.add(token.lower())
    return entries


def is_allowlisted(r, allow):
    if not allow:
        return False
    for field in ("PrincipalId", "Identifier"):
        val = (r.get(field) or "").strip().lower()
        if val and val not in ("n/a", "unknown") and val in allow:
            return True
    return False


def label(r):
    name = r.get("DisplayName") or "Unknown"
    ident = r.get("Identifier") or ""
    who = f"{name} ({ident})" if ident and ident not in ("N/A", "Unknown") else name
    return (
        f"[{r.get('IdentityType', '')}] {who} \u2192 {r.get('RoleName', '')} "
        f"@ {r.get('ScopeType', '')} ({r.get('SubscriptionName', '')})"
    )


baseline = load(os.environ["BASELINE_CSV"])
current = load(os.environ["CURRENT_CSV"])
allow = load_allowlist(os.environ.get("ALLOWLIST_FILE", ""))

red, yellow, info = [], [], []

for key, r in sorted(current.items()):
    if key in baseline:
        continue
    duration = r.get("DurationType", "")
    role = r.get("RoleName", "")
    if is_allowlisted(r, allow):
        info.append(f":white_check_mark: *ALLOWLISTED ADD* {label(r)} ({duration})")
    elif duration == "Permanent" or role in RED_ROLES:
        tag = "NEW PERMANENT" if duration == "Permanent" else "ADDED"
        red.append(f":red_circle: *{tag}* {label(r)} ({duration})")
    else:
        yellow.append(f":yellow_circle: *ADDED* {label(r)} ({duration})")

for key, r in sorted(baseline.items()):
    if key not in current:
        yellow.append(f":yellow_circle: *REMOVED* {label(r)} ({r.get('DurationType', '')})")

for key, cur in sorted(current.items()):
    base = baseline.get(key)
    if not base:
        continue
    if base.get("DurationType") != "Permanent" and cur.get("DurationType") == "Permanent":
        if is_allowlisted(cur, allow):
            info.append(
                f":white_check_mark: *ALLOWLISTED ELEVATION* {label(cur)} "
                f"(was {base.get('DurationType', '')})"
            )
        else:
            red.append(
                f":red_circle: *ELEVATED \u2192 PERMANENT* {label(cur)} "
                f"(was {base.get('DurationType', '')})"
            )

lines = red + yellow + info
if lines:
    print("\n".join(lines))
PY

if [[ -s "$outputFile" ]]; then
    ALERT_COUNT=$(grep -c '_circle:' "$outputFile" || true)
    ALLOW_COUNT=$(grep -c ':white_check_mark:' "$outputFile" || true)
    echo "Detected $ALERT_COUNT alertable and $ALLOW_COUNT allowlisted privileged RBAC change(s); report written to $outputFile"
else
    echo "No privileged RBAC changes detected over the ${windowDays}-day window."
fi
