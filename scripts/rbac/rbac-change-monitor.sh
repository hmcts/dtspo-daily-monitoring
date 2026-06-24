#!/usr/bin/env bash

# Compare two privileged-RBAC snapshot CSVs (produced by audit-privileged-rbac.sh)
# and write a Slack-ready report of what changed between them.
#
# The report file uses the same :red_circle: / :yellow_circle: convention as the
# other monitors, so it can be handed straight to send-slack-header-thread-each-loop.sh
# (which only notifies when one of those markers is present).
#
# Change classification (key = PrincipalId | RoleDefinitionId | Scope |
#                               AssignmentSource | InheritedFromGroupId):
#   :red_circle:    new Permanent privileged assignment, any added Owner /
#                   User Access Administrator, or Temporary -> Permanent elevation
#   :yellow_circle: other added / removed / changed assignments
#   :white_check_mark: allowlisted principal self-adding / self-elevating
#                   (informational only; never triggers a notification on its own)
#
# design hinges on the snapshot filenames being sortable UTC timestamps 
# the manifests sitting beside them with the exact .meta.json extension

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
iacGroupsFiles=()
standingPrivilegeCheck="false"

usage() {
>&2 cat << EOF
    ------------------------------------------------
    Detect privileged RBAC changes between two snapshots
    ------------------------------------------------
    Usage: $0
        [ --currentFile <path> | --currentDir <dir> ]    # latest snapshot CSV (or dir; picks newest)
        [ --baselineFile <path> | --baselineDir <dir> ]  # prior snapshot CSV (default: previous-latest in current dir)
        [ -o | --outputFile <path> ]                     # report file (default: rbac-change-status.txt)
        [ -w | --windowDays <n> ]                        # window size, to compare current run against (default: 2)
        [ -a | --allowlistFile <path> ]                  # principals allowed to self-add (default: <script dir>/allowlist.txt)
        [ --iacGroupsFile <path> ]                       # file of IaC-declared group display names (repeatable); alerting groups not listed are flagged with *
        [ --standingPrivilegeCheck ]                     # also alert on privileged assignments that have PERSISTED past the window and are not IaC-managed/allowlisted (persistence-proof)
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
        --iacGroupsFile) iacGroupsFiles+=("$2"); shift 2 ;;
        --standingPrivilegeCheck) standingPrivilegeCheck="true"; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1" >&2; usage ;;
    esac
done

# Resolve a snapshot path from an explicit file, or by globbing a directory for
# rbac-snapshot-*.csv files (timestamped names sort chronologically). 'rank'
# selects which file, counting back from the newest: 1 = latest, 2 = previous
# latest, and so on. Returns empty if no file matches that rank.
resolve_csv() {
    local file="$1" dir="$2" rank="${3:-1}" match=""
    if [[ -n "$file" ]]; then
        printf '%s' "$file"
        return 0
    fi
    if [[ -n "$dir" ]]; then
        match=$(ls -1 "$dir"/rbac-snapshot-*.csv 2>/dev/null | LC_ALL=C sort -r | sed -n "${rank}p" || true)
        printf '%s' "$match"
    fi
    return 0
}

# Current snapshot: an explicit file, else the latest snapshot in the directory.
CURRENT_CSV="$(resolve_csv "$currentFile" "$currentDir" 1)"

# Baseline snapshot: an explicit file/dir wins; otherwise fall back to the
# "previous latest" (second-newest) snapshot in the current directory.
if [[ -n "$baselineFile" || -n "$baselineDir" ]]; then
    BASELINE_CSV="$(resolve_csv "$baselineFile" "$baselineDir" 1)"
else
    BASELINE_CSV="$(resolve_csv "" "$currentDir" 2)"
fi

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

# Join Access Pkgs tf IaC repo's group-list files (colon-separated) for the diff. 
# The report flags any alerting group whose display name is absent from these
# as not-IaC-managed. Perm changes to IaC managed AP group members is more likely to 
# be legitimate
IAC_GROUPS_FILES=""
if [[ ${#iacGroupsFiles[@]} -gt 0 ]]; then
    IAC_GROUPS_FILES=$(IFS=:; printf '%s' "${iacGroupsFiles[*]}")
    echo "  iac groups: $IAC_GROUPS_FILES"
fi

# Subscription coverage manifests sit next to each snapshot (same stem, .meta.json) and
# record which subscriptions were actually audited. They let us tell a genuinely
# shrunken snapshot apart from one that is merely incomplete, and surface a
# broken/partial audit as a loud alert instead of silent "no changes".
CURRENT_META="${CURRENT_CSV%.csv}.meta.json"
BASELINE_META="${BASELINE_CSV%.csv}.meta.json"

# The CSV is quoted (fields may contain commas), so parse it with Python's csv
# module. Emit Slack-ready lines to the report file.
# pass envvar vars into python
CURRENT_CSV="$CURRENT_CSV" BASELINE_CSV="$BASELINE_CSV" ALLOWLIST_FILE="$allowlistFile" \
CURRENT_META="$CURRENT_META" BASELINE_META="$BASELINE_META" IAC_GROUPS_FILES="$IAC_GROUPS_FILES" \
STANDING_CHECK="$standingPrivilegeCheck" \
python3 - >> "$outputFile" <<'PY'
import csv
import json
import os
from collections import defaultdict
# keep updated with RBAC privileged adm roles 
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
            # Include assignment path dimensions so route-level changes are
            # visible (e.g., user gains same role/scope via a newly added group).
            source = r.get("AssignmentSource", "") or ""
            inherited_group = r.get("InheritedFromGroupId", "") or ""
            key = (
                r.get("PrincipalId", ""),
                r.get("RoleDefinitionId", ""),
                r.get("Scope", ""),
                source,
                inherited_group,
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


def load_iac_groups(joined):
    # Display names of groups declared in IaC (Terraform), loaded from one or more
    # colon-separated files (one name per line; '#' full-line comments and blanks
    # ignored). A group whose name is NOT in this set is flagged with an asterisk
    # in the report. An empty set disables flagging entirely, so a missing/empty
    # source never turns every group into a false 'unmanaged' alert.
    names = set()
    if not joined:
        return names
    for path in joined.split(os.pathsep):
        path = path.strip()
        if not path or not os.path.isfile(path):
            continue
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                s = line.strip()
                if not s or s.startswith("#"):
                    continue
                names.add(s.lower())
    return names

def is_allowlisted(r, allow):
    if not allow:
        return False
    for field in ("PrincipalId", "Identifier"):
        val = (r.get(field) or "").strip().lower()
        if val and val not in ("n/a", "unknown") and val in allow:
            return True
    return False


def label(r):
    # builds slack line
    name = r.get("DisplayName") or "Unknown"
    ident = r.get("Identifier") or ""
    who = f"{name} ({ident})" if ident and ident not in ("N/A", "Unknown") else name
    path = r.get("AssignmentSource", "") or "Direct"
    raw_group = r.get("InheritedFromGroupName", "") or ""
    inherited_group = raw_group or r.get("InheritedFromGroupId", "") or ""
    via = f" via {path}"
    if inherited_group:
        via += f" ({inherited_group})"
        if group_unmanaged(raw_group):
            via += " *"
    return (
        f"[{r.get('IdentityType', '')}] {who} \u2192 {r.get('RoleName', '')} "
        f"@ {r.get('ScopeType', '')} ({r.get('SubscriptionName', '')}){via}"
    )


def load_meta(path):
    # Coverage manifest is optional: older snapshots (or a pre-upgrade baseline)
    # won't have one. Return None so callers can degrade gracefully.
    if not path or not os.path.isfile(path):
        return None
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (ValueError, OSError):
        return None


def coverage_report(cur_meta, base_meta):
    # ensures we are notified loudly of coverage gaps
    """Return (alert_lines, dropped_subscription_ids, gained_subscription_ids).

    dropped_subscription_ids = subscriptions audited in the baseline but NOT in
    the current run. Their per-row 'REMOVED' diffs are suppressed (they are not
    real removals, just blind spots) in favour of one explicit coverage-loss
    alert, so an audit that silently stopped covering a subscription can never be
    mistaken for legitimate clean-up.

    gained_subscription_ids = subscriptions audited in the current run but NOT in
    the baseline (a previously-failed/uncovered subscription that recovered).
    Their pre-existing assignments would otherwise surface as a flood of bogus
    'ADDED' diffs; the caller suppresses those per-row adds and emits one
    coverage-gain note per subscription instead.
    """
    lines = []
    dropped = set()
    gained = set()
    if cur_meta is None:
        # No manifest from the current run: cannot assert coverage. Stay silent so
        # legacy snapshots still diff; the pipeline's failure heartbeat covers a
        # genuinely broken audit.
        return lines, dropped, gained

    for f in cur_meta.get("failedSubscriptions") or []:
        sid = f.get("id", "") or ""
        name = f.get("name", "") or sid or "unknown"
        lines.append(
            f":red_circle: *AUDIT COVERAGE FAILURE* subscription {name} ({sid}) could not be "
            f"audited this run; privileged changes there are UNDETECTED."
        )

    if cur_meta.get("pimEligibleReadable") is False:
        lines.append(
            ":red_circle: *PIM BLIND SPOT* eligible (PIM) group members/owners could not be read "
            "this run (missing PrivilegedAccess.Read.AzureADGroup); eligible privileged access is "
            "not fully covered."
        )

    if base_meta is not None:
        cur_ok = set(cur_meta.get("auditedSubscriptionIds") or [])
        base_ok = set(base_meta.get("auditedSubscriptionIds") or [])
        dropped = base_ok - cur_ok
        gained = cur_ok - base_ok
        for sid in sorted(dropped):
            lines.append(
                f":red_circle: *AUDIT COVERAGE LOSS* subscription {sid} was audited in the baseline "
                f"but is MISSING from the current run; its assignments are no longer monitored "
                f"(removals for it are suppressed to avoid masking real changes)."
            )

    return lines, dropped, gained


baseline = load(os.environ["BASELINE_CSV"])
current = load(os.environ["CURRENT_CSV"])
allow = load_allowlist(os.environ.get("ALLOWLIST_FILE", ""))
cur_meta = load_meta(os.environ.get("CURRENT_META", ""))
base_meta = load_meta(os.environ.get("BASELINE_META", ""))
iac_groups = load_iac_groups(os.environ.get("IAC_GROUPS_FILES", ""))
standing_check = os.environ.get("STANDING_CHECK", "false").lower() == "true"
flagged_groups = set()


def group_unmanaged(name):
    # True when we have IaC data AND this group display name isn't declared there.
    # Records the name so the explanatory footnote is only added when something
    # was actually flagged. With no IaC source loaded we never flag (safe default).
    if name and iac_groups and name.strip().lower() not in iac_groups:
        flagged_groups.add(name)
        return True
    return False


def iac_managed(r):
    # An assignment is treated as IaC-legitimate only when it is inherited from a
    # group whose display name is declared in IaC. Direct assignments (no group)
    # are not recognisable as IaC-managed from the group-name source, so they rely
    # on the allowlist. With no IaC source loaded this is always False.
    name = (r.get("InheritedFromGroupName") or "").strip().lower()
    return bool(name) and name in iac_groups

# Coverage / integrity checks : surface a broken or incomplete audit as a
# loud red alert instead of letting a truncated snapshot masquerade as "no
# changes" or as a wave of legitimate removals.
coverage, dropped_subs, gained_subs = coverage_report(cur_meta, base_meta)

red, yellow, info = [], [], []


def row_is_red(r):
    return r.get("DurationType", "") == "Permanent" or r.get("RoleName", "") in RED_ROLES


def who_label(r):
    name = r.get("DisplayName") or "Unknown"
    ident = r.get("Identifier") or ""
    who = f"{name} ({ident})" if ident and ident not in ("N/A", "Unknown") else name
    return f"[{r.get('IdentityType', '')}] {who}"


def group_summary(verb, rows):
    # Collapse many inherited rows for one (principal, group) pair into a single
    # Slack line, so a membership change that grants/revokes dozens of role
    # assignments produces ONE notification instead of one per role/scope.
    rep = rows[0]
    raw_gname = rep.get("InheritedFromGroupName", "") or ""
    gname = raw_gname or rep.get("InheritedFromGroupId", "") or "unknown group"
    star = " *" if group_unmanaged(raw_gname) else ""
    sources = sorted({r.get("AssignmentSource", "") for r in rows if r.get("AssignmentSource")})
    roles = sorted({r.get("RoleName", "") for r in rows if r.get("RoleName")})
    sub_ids = {r.get("SubscriptionId", "") for r in rows if r.get("SubscriptionId")}
    role_cap = 8
    roles_disp = ", ".join(roles[:role_cap])
    if len(roles) > role_cap:
        roles_disp += f", +{len(roles) - role_cap} more"
    via = ", ".join(sources) if sources else "group"
    across = f" across {len(sub_ids)} subscription(s)" if sub_ids else ""
    return (
        f"{who_label(rep)} {verb} {len(rows)} privileged assignment(s) via group "
        f"\"{gname}\"{star}{across} ({via}); roles: {roles_disp}"
    )


# Partition the added set: Direct assignments stay per-row (genuine individual
# changes); inherited group rows are aggregated per (principal, group) so one
# membership change is one notification, not ~50.
# Rows in subscriptions newly covered this run (gained_subs) are pre-existing
# assignments the audit simply could not see before, NOT new grants. They are
# suppressed and collapsed into a single coverage-gain note per subscription so
# a recovered blind spot cannot masquerade as hundreds of fresh privileged adds.
added_direct = []
added_groups = defaultdict(list)
gained_counts = defaultdict(int)
gained_names = {}
for key, r in current.items():
    if key in baseline:
        continue
    sub_id = r.get("SubscriptionId", "") or ""
    if sub_id in gained_subs:
        gained_counts[sub_id] += 1
        gained_names.setdefault(sub_id, r.get("SubscriptionName", "") or sub_id)
        continue
    gid = r.get("InheritedFromGroupId", "") or ""
    if gid:
        added_groups[(r.get("PrincipalId", ""), gid)].append(r)
    else:
        added_direct.append(r)

# One note per newly-covered subscription (appended to the coverage section).
for sid in sorted(gained_subs):
    n = gained_counts.get(sid, 0)
    name = gained_names.get(sid, sid)
    coverage.append(
        f":yellow_circle: *AUDIT COVERAGE GAINED* subscription {name} ({sid}) is now audited "
        f"(it was NOT covered in the baseline); {n} pre-existing privileged assignment(s) are now "
        f"visible and are NOT new grants (per-row adds suppressed to avoid a false alert flood)."
    )

for r in added_direct:
    duration = r.get("DurationType", "")
    role = r.get("RoleName", "")
    if is_allowlisted(r, allow):
        info.append(f":white_check_mark: *ALLOWLISTED ADD* {label(r)} ({duration})")
    elif duration == "Permanent" or role in RED_ROLES:
        tag = "NEW PERMANENT" if duration == "Permanent" else "ADDED"
        red.append(f":red_circle: *{tag}* {label(r)} ({duration})")
    else:
        yellow.append(f":yellow_circle: *ADDED* {label(r)} ({duration})")

for _pidgid, rows in added_groups.items():
    rep = rows[0]
    if is_allowlisted(rep, allow):
        info.append(f":white_check_mark: *ALLOWLISTED GROUP-INHERITED ADD* {group_summary('gained', rows)}")
    elif any(row_is_red(r) for r in rows):
        red.append(f":red_circle: *GROUP-INHERITED ADD* {group_summary('gained', rows)}")
    else:
        yellow.append(f":yellow_circle: *GROUP-INHERITED ADD* {group_summary('gained', rows)}")

# Partition the removed set the same way. Rows in subscriptions not audited this
# run (dropped_subs) are excluded so a coverage gap is never mistaken for a
# membership removal.
removed_direct = []
removed_groups = defaultdict(list)
for key, r in baseline.items():
    if key in current:
        continue
    if r.get("SubscriptionId", "") in dropped_subs:
        continue
    gid = r.get("InheritedFromGroupId", "") or ""
    if gid:
        removed_groups[(r.get("PrincipalId", ""), gid)].append(r)
    else:
        removed_direct.append(r)

for r in removed_direct:
    yellow.append(f":yellow_circle: *REMOVED* {label(r)} ({r.get('DurationType', '')})")

for _pidgid, rows in removed_groups.items():
    rep = rows[0]
    if is_allowlisted(rep, allow):
        info.append(f":white_check_mark: *ALLOWLISTED GROUP-INHERITED REMOVE* {group_summary('lost', rows)}")
    else:
        yellow.append(f":yellow_circle: *GROUP-INHERITED REMOVE* {group_summary('lost', rows)}")

# this is unlikely to run as our SP doesn't have the correct permissions, we can see
# any new grants as addtional permanent additions
# Elevation (Temporary -> Permanent) stays per-row: it is a property change on a
# specific assignment key, not a membership add/remove.
elevated_keys = set()
for key, cur in current.items():
    base = baseline.get(key)
    if not base:
        continue
    if base.get("DurationType") != "Permanent" and cur.get("DurationType") == "Permanent":
        elevated_keys.add(key)
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

# STANDING PRIVILEGE (state-based persistence check). The diff above only sees
# transitions, so a privileged grant that ages into the baseline becomes
# invisible: a malicious self-elevation left in place for longer than one window
# would normalise and stop alerting. This re-derives, from the CURRENT snapshot,
# every red-role assignment that has PERSISTED across the window (present in the
# baseline too -- the ">24h standing" criterion, using snapshot persistence in
# place of an assignment creation timestamp the audit does not capture) and is
# neither allowlisted nor legitimised by IaC. Such an assignment is re-alerted on
# every run until it is removed or explicitly approved, so persistence is no
# longer a route to silent, undetected privilege. Legitimacy is decided by
# Terraform IaC: an assignment inherited from an IaC-declared group is treated as
# managed/approved; a direct assignment is not recognisable as IaC-managed from
# the group-name source and so must be allowlisted if legitimate. Coverage is
# continuous -- the diff covers a grant's first window (NEW/ADDED), this covers it
# from the second window onward -- so the two checks do not double-report.
if standing_check:
    standing_direct = []
    standing_groups = defaultdict(list)
    standing_suppressed = 0
    for key, r in current.items():
        if not row_is_red(r):
            continue
        if key not in baseline:
            continue  # brand-new this window: already covered by the diff's ADD line
        if key in elevated_keys:
            continue  # already reported above as an elevation (stronger signal)
        if (r.get("SubscriptionId", "") or "") in gained_subs:
            continue  # newly-covered blind spot, not a genuinely persisted grant
        if is_allowlisted(r, allow) or iac_managed(r):
            standing_suppressed += 1
            continue
        gid = r.get("InheritedFromGroupId", "") or ""
        if gid:
            standing_groups[(r.get("PrincipalId", ""), gid)].append(r)
        else:
            standing_direct.append(r)

    for r in standing_direct:
        red.append(
            f":red_circle: *STANDING PRIVILEGE* {label(r)} "
            f"({r.get('DurationType', '')}); persisted >1 window, not IaC-managed or allowlisted"
        )
    for _pidgid, rows in standing_groups.items():
        red.append(
            f":red_circle: *STANDING PRIVILEGE* {group_summary('holds', rows)}; "
            f"persisted >1 window, group not IaC-managed or allowlisted"
        )
    if standing_suppressed:
        info.append(
            f":white_check_mark: *STANDING PRIVILEGE RECONCILED* {standing_suppressed} persisted "
            f"privileged assignment(s) matched IaC/allowlist and were suppressed."
        )

red.sort()
yellow.sort()
info.sort()
lines = coverage + red + yellow + info
if flagged_groups:
    lines.append(
        "_Note: any group marked with * is NOT managed via IaC and should be "
        "scrutinised._"
    )
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
