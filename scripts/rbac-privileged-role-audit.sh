#!/usr/bin/env bash

# =============================================================================
# Azure Production Privileged Role Audit - Daily Monitor
# =============================================================================
# Finds human users with privileged roles across production management groups
# and subscriptions, then reports findings to Slack.
#
# Scope:
#   Management Groups: CFT - Production, Crime, Heritage - Production,
#                      Platform - Production, SDS - Production, SPS - Production
#   Subscriptions: HMCTS-SOC-PROD
#
# Exceptions are managed in scripts/prod_audit_exceptions.yaml
# =============================================================================

set -euo pipefail

# Source central functions script
source scripts/common-functions.sh

slackBotToken=
slackChannelName=
removeDirectRequested=false
removeDirect=false

usage(){
>&2 cat << EOF
    ------------------------------------------------
    Azure Production Privileged Role Audit
    ------------------------------------------------
    Usage: $0
        [ -t | --slackBotToken ]
        [ -c | --slackChannelName ]
        [ --remove-direct ]  Enable Saturday scheduled cleanup of direct user assignments
                             and user memberships of groups that give privileged access
        [ -h | --help ]
EOF
exit 1
}

args=$(getopt -a -o t:c:h --long slackBotToken:,slackChannelName:,remove-direct,help -- "$@")
if [[ $? -gt 0 ]]; then
    usage
fi

eval set -- ${args}
while :
do
    case $1 in
        -h | --help)              usage                    ; shift   ;;
        -t | --slackBotToken)     slackBotToken=$2         ; shift 2 ;;
        -c | --slackChannelName)  slackChannelName=$2      ; shift 2 ;;
        --remove-direct)          removeDirectRequested=true ; shift ;;
        --) shift; break ;;
        *) >&2 echo Unsupported option: $1
            usage ;;
    esac
done

if [[ "$removeDirectRequested" == true ]]; then
    if [[ "${BUILD_REASON:-}" == "Schedule" &&
          "${BUILD_SOURCEBRANCH:-}" == "refs/heads/master" &&
          "${BUILD_CRONSCHEDULE_DISPLAYNAME:-}" == "Saturday morning daily checks and RBAC cleanup" ]]; then
        removeDirect=true
    else
        echo "Direct-role cleanup is disabled outside the Saturday morning schedule on master; running the audit only."
    fi
fi

if [[ -z "$slackBotToken" || -z "$slackChannelName" ]]; then
    {
        echo "------------------------"
        echo 'Please supply all of: '
        echo '- Slack token'
        echo '- Slack channel name'
        echo "------------------------"
    } >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXCEPTIONS_FILE="$SCRIPT_DIR/prod_audit_exceptions.yaml"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

RAW_ASSIGNMENTS_FILE="$WORK_DIR/raw_role_assignments.json"
PRIVILEGED_ROLES_FILE="$WORK_DIR/privileged_roles.json"
FINDINGS_JSON="$WORK_DIR/findings.json"
CLEANUP_REMOVED_FILE="$WORK_DIR/cleanup_removed_count.txt"
CLEANUP_FAILURES_FILE="$WORK_DIR/cleanup_failures.txt"
CLEANUP_GROUP_REMOVED_FILE="$WORK_DIR/cleanup_group_removed_count.txt"

echo "============================================================================="
echo "Azure Production Privileged Role Audit"
echo "============================================================================="

# =============================================================================
# Step 1: Dynamically fetch privileged role definitions from Azure
# =============================================================================
echo "[Step 1/4] Fetching privileged role definitions from Azure..."

python3 - "$PRIVILEGED_ROLES_FILE" "$removeDirect" << 'FETCH_ROLES_PY'
import json
import sys
import subprocess

output_file = sys.argv[1]
remove_direct = sys.argv[2] == 'true'

# Privileged action patterns — roles granting any of these are considered privileged
PRIVILEGED_ACTION_PATTERNS = [
    "*",                                          # Owner (full control)
    "Microsoft.Authorization/*/write",            # RBAC write
    "Microsoft.Authorization/roleAssignments/write",
    "Microsoft.Authorization/roleDefinitions/write",
    "Microsoft.Authorization/elevateAccess/Action",
    "Microsoft.Authorization/accessReviewScheduleDefinitions/write",
]

def is_privileged(actions):
    for action in actions:
        a = action.strip().lower()
        for pattern in PRIVILEGED_ACTION_PATTERNS:
            if a == pattern.lower() or a == "*":
                return True
    return False

print("  Querying Azure role definitions...")
role_lookup_complete = False
try:
    result = subprocess.run(
        ['az', 'role', 'definition', 'list',
         '--query', "[].{id:name,roleName:roleName,roleType:roleType,actions:permissions[0].actions}",
         '-o', 'json'],
        capture_output=True, text=True, timeout=120
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr[:300])
    all_roles = json.loads(result.stdout)
    role_lookup_complete = True
except Exception as e:
    print(f"  ERROR fetching role definitions: {e}")
    if remove_direct:
        raise SystemExit("Direct-role cleanup aborted because role definitions could not be enumerated.")
    print("  Falling back to built-in privileged role list.")
    all_roles = []

privileged_roles = {}
for role in all_roles:
    actions = role.get('actions') or []
    if is_privileged(actions):
        role_id = role.get('id', '')
        # role definition id is a GUID (last segment of the full resource path)
        guid = role_id.split('/')[-1] if '/' in role_id else role_id
        if guid:
            privileged_roles[guid] = {
                'roleName': role.get('roleName', guid),
                'roleType': role.get('roleType', 'BuiltInRole'),
            }

# Always include these critical roles as a safety net in case the query misses them
FALLBACK_ROLES = {
    "8e3af657-a8ff-443c-a75c-2fe8c4bcb635": {"roleName": "Owner",                                    "roleType": "BuiltInRole"},
    "b24988ac-6180-42a0-ab88-20f7382dd24c": {"roleName": "Contributor",                              "roleType": "BuiltInRole"},
    "18d7d88d-d35e-4fb5-a5c3-7773c20a72d9": {"roleName": "User Access Administrator",                "roleType": "BuiltInRole"},
    "f58310d9-a9f6-439a-9e8d-f62e7b41a168": {"roleName": "Role Based Access Control Administrator",  "roleType": "BuiltInRole"},
    "76cc9ee4-d5d3-4a45-a930-26add3d73475": {"roleName": "Access Review Operator Service Principal", "roleType": "BuiltInRole"},
}
for guid, info in FALLBACK_ROLES.items():
    privileged_roles.setdefault(guid, info)

with open(output_file, 'w') as f:
    json.dump({'roles': privileged_roles, 'lookupComplete': role_lookup_complete}, f, indent=2)

print(f"  Privileged roles identified: {len(privileged_roles)}")
for guid, info in sorted(privileged_roles.items(), key=lambda x: x[1]['roleName']):
    print(f"    [{info['roleType']}] {info['roleName']} ({guid})")
FETCH_ROLES_PY

echo ""

# =============================================================================
# Step 2: Resolve management group IDs and child subscriptions
# =============================================================================
echo "[Step 2/4] Resolving management groups and child subscriptions..."

if ! az rest --method GET \
    --uri "https://management.azure.com/providers/Microsoft.Management/managementGroups?api-version=2020-05-01" \
    -o json > "$WORK_DIR/all_management_groups_rest.json" 2>/dev/null; then
    if [[ "$removeDirect" == true ]]; then
        echo "ERROR: Direct-role cleanup aborted because management groups could not be enumerated." >&2
        exit 1
    fi
    echo '{"value":[]}' > "$WORK_DIR/all_management_groups_rest.json"
fi

if [[ "$removeDirect" == true ]] && jq -e '.nextLink != null' "$WORK_DIR/all_management_groups_rest.json" >/dev/null; then
    echo "ERROR: Direct-role cleanup aborted because management-group enumeration is paginated." >&2
    exit 1
fi

jq '[.value[] | {name: .name, displayName: .properties.displayName}]' \
    "$WORK_DIR/all_management_groups_rest.json" > "$WORK_DIR/all_management_groups.json"

python3 - "$WORK_DIR/all_management_groups.json" "$removeDirect" << 'RESOLVE_MG_PY'
import json
import sys
import subprocess

mg_file = sys.argv[1]
remove_direct = sys.argv[2] == 'true'

TARGET_MG_DISPLAY_NAMES = [
    "CFT - Production",
    "Crime",
    "Heritage - Production",
    "Platform - Production",
    "SDS - Production",
    "SPS - Production",
]

TARGET_SUBSCRIPTIONS = [
    "HMCTS-SOC-PROD",
]

with open(mg_file, 'r') as f:
    all_mgs = json.load(f)

mg_map = {}
for mg in all_mgs:
    display = mg.get('displayName', '')
    name = mg.get('name', '')
    if display in TARGET_MG_DISPLAY_NAMES:
        mg_map[display] = name
        print(f"  Found management group: {display} -> {name}")

for target in TARGET_MG_DISPLAY_NAMES:
    if target not in mg_map:
        print(f"  WARNING: Management group '{target}' not found!")
        if remove_direct:
            raise SystemExit(f"Direct-role cleanup aborted: management group '{target}' was not found.")

all_subscription_ids = set()
mg_subscriptions = {}

for display_name, mg_id in mg_map.items():
    print(f"  Getting child subscriptions for: {display_name}")
    try:
        result = subprocess.run(
            ['az', 'rest', '--method', 'GET',
             '--uri', f"https://management.azure.com/providers/Microsoft.Management/managementGroups/{mg_id}/descendants?api-version=2020-05-01&%24top=1000",
             '-o', 'json'],
            capture_output=True, text=True, timeout=60
        )
        if result.returncode == 0:
            data = json.loads(result.stdout)
            if remove_direct and data.get('nextLink'):
                raise SystemExit(f"Direct-role cleanup aborted: child subscriptions for '{display_name}' require pagination.")
            descendants = data.get('value', [])
            sub_ids = [
                d.get('name', '')
                for d in descendants
                if d.get('type', '').lower() == 'microsoft.management/managementgroups/subscriptions'
            ]
            mg_subscriptions[display_name] = sub_ids
            all_subscription_ids.update(s for s in sub_ids if s)
            print(f"    Found {len(sub_ids)} child subscriptions")
        else:
            mg_subscriptions[display_name] = []
            print(f"    WARNING: Could not get child subscriptions: {result.stderr[:200]}")
            if remove_direct:
                raise SystemExit(f"Direct-role cleanup aborted: child subscriptions for '{display_name}' could not be enumerated.")
    except Exception as e:
        mg_subscriptions[display_name] = []
        print(f"    ERROR: {e}")
        if remove_direct:
            raise SystemExit(f"Direct-role cleanup aborted: child subscriptions for '{display_name}' could not be enumerated.")

print(f"\n  Resolving target subscriptions...")
try:
    result = subprocess.run(
        ['az', 'account', 'list', '--query',
         "[?name=='HMCTS-SOC-PROD'].id", '-o', 'json'],
        capture_output=True, text=True, timeout=30
    )
    if result.returncode == 0:
        target_sub_ids = json.loads(result.stdout)
        for sid in target_sub_ids:
            sid_clean = sid.split('/')[-1] if '/' in sid else sid
            all_subscription_ids.add(sid_clean)
            print(f"  Found HMCTS-SOC-PROD: {sid_clean}")
        if remove_direct and not target_sub_ids:
            raise SystemExit("Direct-role cleanup aborted: HMCTS-SOC-PROD subscription was not found.")
    elif remove_direct:
        raise SystemExit(f"Direct-role cleanup aborted: target subscriptions could not be enumerated: {result.stderr[:300]}")
except Exception as e:
    print(f"  ERROR resolving HMCTS-SOC-PROD: {e}")
    if remove_direct:
        raise SystemExit("Direct-role cleanup aborted: target subscriptions could not be enumerated.")

output = {
    'management_groups': mg_map,
    'mg_subscriptions': mg_subscriptions,
    'all_subscription_ids': list(all_subscription_ids),
    'target_subscriptions_direct': TARGET_SUBSCRIPTIONS
}

with open(mg_file.replace('all_management_groups.json', 'resolved_scope.json'), 'w') as f:
    json.dump(output, f, indent=2)

print(f"\n  Total unique subscriptions in scope: {len(all_subscription_ids)}")
RESOLVE_MG_PY

echo ""

# =============================================================================
# Step 3: Query role assignments and resolve identities
# =============================================================================
echo "[Step 3/4] Querying role assignments across in-scope resources..."

python3 - "$WORK_DIR/resolved_scope.json" "$RAW_ASSIGNMENTS_FILE" "$PRIVILEGED_ROLES_FILE" "$removeDirect" << 'QUERY_PY'
import json
import sys
import subprocess

scope_file = sys.argv[1]
output_file = sys.argv[2]
privileged_roles_file = sys.argv[3]
remove_direct = sys.argv[4] == 'true'

with open(privileged_roles_file, 'r') as f:
    priv_data = json.load(f)

PRIVILEGED_ROLE_GUIDS = {}
for role_id, role_info in priv_data.get('roles', {}).items():
    PRIVILEGED_ROLE_GUIDS[role_id] = role_info.get('roleName', role_id)
if remove_direct and not priv_data.get('lookupComplete'):
    raise SystemExit("Direct-role cleanup aborted because privileged role definitions were not completely enumerated.")

with open(scope_file, 'r') as f:
    scope_data = json.load(f)

mg_map = scope_data.get('management_groups', {})
all_sub_ids = scope_data.get('all_subscription_ids', [])

all_assignments = []

print("  Querying management group level assignments...")
for display_name, mg_id in mg_map.items():
    print(f"    Checking: {display_name}")
    try:
        result = subprocess.run(
            ['az', 'role', 'assignment', 'list',
             '--scope', f"/providers/Microsoft.Management/managementGroups/{mg_id}",
             '--query', "[?principalType=='User' || principalType=='Group'].{assignmentId:id,principalId:principalId,principalType:principalType,roleDefinitionName:roleDefinitionName,roleDefinitionId:roleDefinitionId,scope:scope}",
             '-o', 'json'],
            capture_output=True, text=True, timeout=60
        )
        if result.returncode == 0:
            assignments = json.loads(result.stdout)
            for a in assignments:
                role_def_id = a.get('roleDefinitionId', '')
                role_name = a.get('roleDefinitionName', '')
                is_privileged = False
                matched_role = role_name
                for guid, rname in PRIVILEGED_ROLE_GUIDS.items():
                    if guid.lower() in role_def_id.lower():
                        is_privileged = True
                        matched_role = rname
                        break
                if not is_privileged and role_name in PRIVILEGED_ROLE_GUIDS.values():
                    is_privileged = True
                if is_privileged:
                    a['resolvedRoleName'] = matched_role
                    a['sourceScope'] = display_name
                    all_assignments.append(a)
        else:
            if remove_direct:
                raise SystemExit(f"Direct-role cleanup aborted: role assignments for management group '{display_name}' could not be enumerated: {result.stderr[:300]}")
    except Exception as e:
        print(f"      ERROR: {e}")
        if remove_direct:
            raise SystemExit(f"Direct-role cleanup aborted while querying management group '{display_name}'.")

print(f"\n  Querying {len(all_sub_ids)} subscriptions...")
for i, sub_id in enumerate(all_sub_ids):
    if (i + 1) % 10 == 0 or i == 0:
        print(f"    Progress: {i + 1}/{len(all_sub_ids)}")
    try:
        result = subprocess.run(
            ['az', 'role', 'assignment', 'list',
             '--all',
             '--subscription', sub_id,
             '--query', "[?principalType=='User' || principalType=='Group'].{assignmentId:id,principalId:principalId,principalType:principalType,roleDefinitionName:roleDefinitionName,roleDefinitionId:roleDefinitionId,scope:scope}",
             '-o', 'json'],
            capture_output=True, text=True, timeout=120
        )
        if result.returncode == 0:
            assignments = json.loads(result.stdout)
            for a in assignments:
                role_def_id = a.get('roleDefinitionId', '')
                role_name = a.get('roleDefinitionName', '')
                is_privileged = False
                matched_role = role_name
                for guid, rname in PRIVILEGED_ROLE_GUIDS.items():
                    if guid.lower() in role_def_id.lower():
                        is_privileged = True
                        matched_role = rname
                        break
                if not is_privileged and role_name in PRIVILEGED_ROLE_GUIDS.values():
                    is_privileged = True
                if is_privileged:
                    a['resolvedRoleName'] = matched_role
                    a['sourceScope'] = f"Subscription: {sub_id}"
                    all_assignments.append(a)
    except Exception as e:
        if remove_direct:
            raise SystemExit(f"Direct-role cleanup aborted while querying subscription '{sub_id}': {e}")
        continue
    if result.returncode != 0 and remove_direct:
        raise SystemExit(f"Direct-role cleanup aborted: role assignments for subscription '{sub_id}' could not be enumerated: {result.stderr[:300]}")

# Deduplicate by (principalId, roleDefinitionId, scope)
seen = set()
unique_assignments = []
for a in all_assignments:
    key = (a.get('assignmentId', ''), a.get('principalId', ''), a.get('roleDefinitionId', ''), a.get('scope', ''))
    if key not in seen:
        seen.add(key)
        unique_assignments.append(a)

print(f"  Unique assignments after dedup: {len(unique_assignments)}")

with open(output_file, 'w') as f:
    json.dump(unique_assignments, f, indent=2)
QUERY_PY

echo ""

# =============================================================================
# Step 4: Resolve identities, apply exceptions, build findings JSON
# =============================================================================
echo "[Step 4/4] Resolving identities, applying exceptions, building findings..."

python3 - "$RAW_ASSIGNMENTS_FILE" "$FINDINGS_JSON" "$PRIVILEGED_ROLES_FILE" "$WORK_DIR/resolved_scope.json" "$EXCEPTIONS_FILE" "$removeDirect" "$CLEANUP_REMOVED_FILE" "$CLEANUP_FAILURES_FILE" "$CLEANUP_GROUP_REMOVED_FILE" << 'PROCESS_PY'
import json
import sys
import subprocess
import re
import os
from collections import defaultdict

raw_file = sys.argv[1]
findings_file = sys.argv[2]
privileged_roles_file = sys.argv[3]
scope_file = sys.argv[4]
exceptions_file = sys.argv[5]
remove_direct = sys.argv[6] == 'true'
cleanup_removed_file = sys.argv[7]
cleanup_failures_file = sys.argv[8]
cleanup_group_removed_file = sys.argv[9]

def get_scope_level(scope):
    if '/providers/Microsoft.Management/managementGroups/' in scope:
        return 0
    parts = scope.split('/')
    if len(parts) <= 3:
        return 1
    if len(parts) <= 5 and '/resourceGroups/' in scope:
        return 2
    return 3

def get_scope_type_label(level):
    return {0: 'Management Group', 1: 'Subscription', 2: 'Resource Group', 3: 'Resource'}.get(level, 'Resource')

with open(scope_file, 'r') as f:
    scope_data = json.load(f)

mg_map = scope_data.get('management_groups', {})
mg_subscriptions = scope_data.get('mg_subscriptions', {})

sub_governed_by_mg = defaultdict(set)
for display_name, sub_ids in mg_subscriptions.items():
    mg_id = mg_map.get(display_name, '')
    if mg_id:
        mg_scope = f"/providers/Microsoft.Management/managementGroups/{mg_id}"
        for sub_id in sub_ids:
            sub_governed_by_mg[sub_id].add(mg_scope)

def scope_contains(parent_scope, child_scope):
    parent_lower = parent_scope.lower().rstrip('/')
    child_lower = child_scope.lower().rstrip('/')
    if parent_lower == child_lower:
        return False
    if child_lower.startswith(parent_lower + '/'):
        return True
    sub_match = re.search(r'/subscriptions/([^/]+)', child_scope, re.IGNORECASE)
    if sub_match:
        sub_id = sub_match.group(1)
        if parent_scope in sub_governed_by_mg.get(sub_id, set()):
            return True
    return False

def is_service_account(upn, display_name):
    check_str = (upn + ' ' + display_name).lower()
    service_patterns = [
        r'^dts-', r'^dts[a-z]', r'^svc-', r'^svc[a-z]',
        r'^service', r'^app-', r'service\s*account',
        r'automation', r'^azure', r'^aad', r'@microsoft\.com$',
        r'breakglass', r'emergency', r'shared',
        r'_admin@', r'^admin[._-]',
    ]
    for pattern in service_patterns:
        if re.search(pattern, check_str, re.IGNORECASE):
            return True
    return False

def get_subscription_name(scope, sub_names):
    match = re.search(r'/subscriptions/([^/]+)', scope)
    if match:
        return sub_names.get(match.group(1), match.group(1))
    if '/managementGroups/' in scope:
        match = re.search(r'/managementGroups/([^/]+)', scope)
        return f"MG: {match.group(1)}" if match else scope
    return scope

with open(raw_file, 'r') as f:
    assignments = json.load(f)

def parse_exceptions_yaml(path):
    result = {'excluded_subscriptions': [], 'allowed_assignments': [], 'group_cleanup_exempt_principals': []}
    try:
        with open(path, 'r') as f:
            lines = f.readlines()
    except FileNotFoundError:
        if remove_direct:
            raise SystemExit("Direct-role cleanup aborted because the exceptions file is missing.")
        return result
    current_section = None
    current_item = None
    for raw_line in lines:
        line = raw_line.rstrip()
        stripped = line.lstrip()
        if not stripped or stripped.startswith('#'):
            continue
        indent = len(line) - len(stripped)
        if indent == 0 and stripped.endswith(':'):
            current_section = stripped[:-1]
            current_item = None
            continue
        if indent == 2 and stripped.startswith('- '):
            value = stripped[2:].strip()
            if current_section in ('excluded_subscriptions', 'group_cleanup_exempt_principals'):
                result[current_section].append(value)
                current_item = None
            elif current_section == 'allowed_assignments':
                current_item = {}
                result['allowed_assignments'].append(current_item)
                if ':' in value:
                    k, _, v = value.partition(':')
                    current_item[k.strip()] = v.strip()
            continue
        if indent >= 4 and ':' in stripped and current_item is not None:
            k, _, v = stripped.partition(':')
            current_item[k.strip()] = v.strip()
            continue
    return result

exceptions = parse_exceptions_yaml(exceptions_file)
if remove_direct and any(
    not item.get('principal_name') or not item.get('role') or not item.get('scope')
    for item in exceptions.get('allowed_assignments', [])
):
    raise SystemExit("Direct-role cleanup aborted because an allowed exception is incomplete.")
print(f"  Exceptions: {len(exceptions.get('excluded_subscriptions', []))} excluded subscriptions, "
      f"{len(exceptions.get('allowed_assignments', []))} allowed assignments")

sys.path.insert(0, os.path.abspath('scripts'))
from rbac_exception_scopes import exception_scope_matches, load_management_group_descendants
from remove_privileged_group_memberships import remove_group_memberships, validate_group_memberships

# Management-group exceptions also cover their descendant subscriptions and child management groups.
try:
    exception_descendants = load_management_group_descendants(
        exc.get('scope', '') for exc in exceptions.get('allowed_assignments', [])
    )
except Exception as e:
    if remove_direct:
        raise SystemExit(f"Cleanup aborted because exception scopes could not be resolved: {e}")
    print(f"  WARNING: Could not resolve management-group exception scopes: {e}")
    exception_descendants = {}

excluded_sub_names = set(s.lower() for s in exceptions.get('excluded_subscriptions', []))

sub_names = {}
sub_ids_by_name = {}
account_list_complete = False
try:
    result = subprocess.run(
        ['az', 'account', 'list', '--query', "[].{id:id,name:name}", '-o', 'json'],
        capture_output=True, text=True, timeout=30
    )
    if result.returncode == 0:
        account_list_complete = True
        for s in json.loads(result.stdout):
            sid = s['id'].split('/')[-1] if '/' in s['id'] else s['id']
            sub_names[sid] = s['name']
            sub_ids_by_name[s['name'].lower()] = sid
except:
    if remove_direct:
        raise SystemExit("Direct-role cleanup aborted because subscription names could not be resolved.")

excluded_sub_ids = set()
for name in excluded_sub_names:
    sid = sub_ids_by_name.get(name)
    if sid:
        excluded_sub_ids.add(sid.lower())
    else:
        excluded_sub_ids.add(name.lower())
if remove_direct:
    unresolved_exclusions = excluded_sub_names - set(sub_ids_by_name)
    if not account_list_complete or unresolved_exclusions:
        raise SystemExit(
            "Direct-role cleanup aborted because excluded subscriptions could not be resolved: "
            + ", ".join(sorted(unresolved_exclusions))
        )

def is_excluded_scope(scope):
    m = re.search(r'/subscriptions/([^/]+)', scope, re.IGNORECASE)
    return bool(m and m.group(1).lower() in excluded_sub_ids)

def is_allowed_exception(upn, display_name, role, scope, group_name):
    for exc in exceptions.get('allowed_assignments', []):
        principal = exc.get('principal_name', '').lower()
        exc_role = exc.get('role', '*')
        exc_scope = exc.get('scope', '').rstrip('/')
        principal_match = (
            principal in upn.lower() or
            principal in display_name.lower() or
            principal in group_name.lower()
        )
        role_match = exc_role == '*' or exc_role.lower() == role.lower()
        scope_match = exception_scope_matches(exc_scope, scope, exception_descendants)
        if principal_match and role_match and scope_match:
            return True
    return False

assignments = [a for a in assignments if not is_excluded_scope(a.get('scope', ''))]

user_assignments = [a for a in assignments if a.get('principalType') == 'User']
group_assignments = [a for a in assignments if a.get('principalType') == 'Group']

user_ids = list(set(a['principalId'] for a in user_assignments if a.get('principalId')))
print(f"  Resolving {len(user_ids)} unique users...")
user_info = {}
for i, uid in enumerate(user_ids):
    try:
        result = subprocess.run(
            ['az', 'ad', 'user', 'show', '--id', uid,
             '--query', '{upn:userPrincipalName,displayName:displayName}',
             '-o', 'json'],
            capture_output=True, text=True, timeout=15
        )
        if result.returncode == 0:
            info = json.loads(result.stdout)
            user_info[uid] = {
                'upn': info.get('upn', uid),
                'displayName': info.get('displayName', ''),
                'resolved': bool(info.get('upn')),
            }
        else:
            user_info[uid] = {'upn': uid, 'displayName': '', 'resolved': False}
    except:
        user_info[uid] = {'upn': uid, 'displayName': '', 'resolved': False}
if remove_direct and any(not user_info.get(uid, {}).get('resolved') for uid in user_ids):
    raise SystemExit("Direct-role cleanup aborted because one or more user identities could not be resolved.")

group_ids = list(set(a['principalId'] for a in group_assignments if a.get('principalId')))
print(f"  Resolving {len(group_ids)} groups and their members...")
group_info = {}
group_members = {}
for gid in group_ids:
    try:
        result = subprocess.run(
            ['az', 'ad', 'group', 'show', '--group', gid,
             '--query', '{displayName:displayName}', '-o', 'json'],
            capture_output=True, text=True, timeout=15
        )
        group_info[gid] = json.loads(result.stdout).get('displayName', gid) if result.returncode == 0 else gid
    except:
        group_info[gid] = gid
    try:
        result = subprocess.run(
            ['az', 'ad', 'group', 'member', 'list', '--group', gid, '-o', 'json'],
            capture_output=True, text=True, timeout=60
        )
        if result.returncode == 0:
            members = json.loads(result.stdout)
            group_members[gid] = [
                {'id': m.get('id', ''), 'upn': m.get('userPrincipalName', ''), 'displayName': m.get('displayName', '')}
                for m in members
                if m.get('@odata.type') != '#microsoft.graph.user' or
                not is_service_account(m.get('userPrincipalName', ''), m.get('displayName', ''))
                if m.get('@odata.type', '') in ['#microsoft.graph.user', '']
            ]
        else:
            group_members[gid] = []
    except:
        group_members[gid] = []

# Check audit logs for recently-added group members (skip members added < 24h ago)
# Graph audit log structure for "Add member to group":
#   targetResources[0]: the group  -> type == "Group", id == group object ID
#   targetResources[1]: the member -> type == "User",  id == user object ID
from datetime import datetime, timedelta, timezone
since = (datetime.now(timezone.utc) - timedelta(hours=25)).strftime('%Y-%m-%dT%H:%M:%SZ')
recently_added_to_group = set()
try:
    url = (
        "https://graph.microsoft.com/v1.0/auditLogs/directoryAudits"
        f"?$filter=activityDisplayName eq 'Add member to group'"
        f" and activityDateTime ge {since}&$top=500"
    )
    entries = []
    while url:
        result = subprocess.run(
            ['az', 'rest', '--method', 'GET', '--url', url],
            capture_output=True, text=True, timeout=120
        )
        if result.returncode != 0:
            raise RuntimeError(f"exit {result.returncode}: {result.stderr[:300]}")
        audit_data = json.loads(result.stdout)
        entries.extend(audit_data.get('value', []))
        url = audit_data.get('@odata.nextLink')
    group_ids_set = set(g.lower() for g in group_ids)
    print(f"  Audit log: {len(entries)} 'Add member to group' events in last 25h")
    for entry in entries:
        target_resources = entry.get('targetResources', [])
        matched_group_id = None
        added_user_id = None
        for tr in target_resources:
            tr_type = (tr.get('type') or '').lower()
            tr_id = (tr.get('id') or '').lower()
            if tr_type == 'group' and tr_id in group_ids_set:
                matched_group_id = tr_id
            elif tr_type == 'user' and tr.get('id'):
                added_user_id = tr.get('id', '').lower()
        if matched_group_id and added_user_id:
            recently_added_to_group.add((matched_group_id, added_user_id))
    print(f"  Members added to in-scope groups in last 25h: {len(recently_added_to_group)}")
except Exception as e:
    # Recent additions include just-in-time access-package grants, which must not be removed.
    if remove_direct:
        raise SystemExit(f"Cleanup aborted because recent group additions could not be read: {e}")
    print(f"  WARNING: Could not query audit logs: {e}")

# Build findings
findings = []

for a in user_assignments:
    pid = a.get('principalId', '')
    uinfo = user_info.get(pid, {})
    upn = uinfo.get('upn', pid)
    display_name = uinfo.get('displayName', '')
    if is_service_account(upn, display_name):
        continue
    role = a.get('resolvedRoleName', a.get('roleDefinitionName', ''))
    scope = a.get('scope', '')
    if is_allowed_exception(upn, display_name, role, scope, ''):
        continue
    findings.append({
        'upn': upn, 'displayName': display_name, 'principalId': pid,
        'role': role, 'scope': scope, 'scopeLevel': get_scope_level(scope),
        'accessType': 'Direct', 'principalType': 'User', 'groupName': '',
        'assignmentId': a.get('assignmentId', ''),
    })

group_cleanup_exempt = set(p.lower() for p in exceptions.get('group_cleanup_exempt_principals', []))
group_cleanup_candidates = {}

for a in group_assignments:
    gid = a.get('principalId', '')
    gname = group_info.get(gid, gid)
    role = a.get('resolvedRoleName', a.get('roleDefinitionName', ''))
    scope = a.get('scope', '')
    for m in group_members.get(gid, []):
        if (gid.lower(), m['id'].lower()) in recently_added_to_group:
            continue
        cleanup_candidate = (
            remove_direct
            and m['id'].lower() not in group_cleanup_exempt
            and m['upn'].lower() not in group_cleanup_exempt
        )
        candidate = {'groupId': gid, 'groupName': gname, 'principalId': m['id'], 'upn': m['upn']}
        if is_allowed_exception(m['upn'], m['displayName'], role, scope, gname):
            continue
        if cleanup_candidate:
            group_cleanup_candidates[(gid.lower(), m['id'].lower())] = candidate
        findings.append({
            'upn': m['upn'], 'displayName': m['displayName'], 'principalId': m['id'],
            'role': role, 'scope': scope, 'scopeLevel': get_scope_level(scope),
            'accessType': 'Via Group', 'principalType': 'Group', 'groupName': gname,
            'groupId': gid,
        })

if remove_direct:
    direct_candidates = [
        {
            'accessType': finding['accessType'],
            'principalType': finding['principalType'],
            'assignmentId': finding['assignmentId'],
            'scope': finding['scope'],
            'upn': finding['upn'],
            'role': finding['role'],
        }
        for finding in findings
        if finding.get('accessType') == 'Direct'
    ]
    from remove_direct_privileged_assignments import remove_direct_assignments

    group_candidates = list(group_cleanup_candidates.values())
    validate_group_memberships(group_candidates)
    removed_ids, cleanup_failures = remove_direct_assignments(direct_candidates)
    removed_memberships, group_failures = remove_group_memberships(group_candidates)
    cleanup_failures += group_failures
    findings = [
        finding for finding in findings
        if not (finding.get('accessType') == 'Direct' and finding.get('assignmentId') in removed_ids)
        and not (
            finding.get('accessType') == 'Via Group'
            and (finding.get('groupId', '').lower(), finding.get('principalId', '').lower()) in removed_memberships
        )
    ]
    with open(cleanup_removed_file, 'w') as fh:
        fh.write(str(len(removed_ids)))
    with open(cleanup_group_removed_file, 'w') as fh:
        fh.write(str(len(removed_memberships)))
    with open(cleanup_failures_file, 'w') as fh:
        for failure in cleanup_failures:
            fh.write(failure + '\n')
    print(f"  Direct privileged assignments removed: {len(removed_ids)}")
    print(f"  Group memberships removed: {len(removed_memberships)}")
    if cleanup_failures:
        print(f"  ERROR: {len(cleanup_failures)} cleanup action(s) failed.")
        for failure in cleanup_failures:
            print(f"    {failure}")

# De-duplication (exact -> scope hierarchy -> group consolidation)
seen_exact = set()
unique_findings = []
for f in findings:
    key = (f['upn'], f['role'], f['accessType'], f['groupName'], f['scope'])
    if key not in seen_exact:
        seen_exact.add(key)
        unique_findings.append(f)

mg_sub_sets = {}
for display_name, sub_ids in mg_subscriptions.items():
    mg_id = mg_map.get(display_name, '')
    if mg_id:
        mg_sub_sets[f"/providers/Microsoft.Management/managementGroups/{mg_id}"] = (display_name, set(sub_ids))

def extract_sub_id(scope):
    m = re.search(r'/subscriptions/([^/]+)', scope, re.IGNORECASE)
    return m.group(1) if m else None

user_role_map = defaultdict(list)
for f in unique_findings:
    user_role_map[(f['upn'], f['role'], f['accessType'], f['groupName'])].append(f)

after_pass1 = []
for key, entries in user_role_map.items():
    entries.sort(key=lambda x: x['scopeLevel'])
    kept = []
    for entry in entries:
        if not any(scope_contains(k['scope'], entry['scope']) for k in kept):
            kept.append(entry)
    after_pass1.extend(kept)

user_role_group_map = defaultdict(list)
for f in after_pass1:
    user_role_group_map[(f['upn'], f['role'], f['accessType'], f['groupName'])].append(f)

deduplicated = []
for key, entries in user_role_group_map.items():
    sub_entries = [e for e in entries if e['scopeLevel'] == 1]
    other_entries = [e for e in entries if e['scopeLevel'] != 1]
    if len(sub_entries) > 1:
        entry_sub_ids = set(extract_sub_id(e['scope']) for e in sub_entries if extract_sub_id(e['scope']))
        consolidated = False
        for mg_scope, (mg_display, mg_sub_id_set) in mg_sub_sets.items():
            if entry_sub_ids.issubset(mg_sub_id_set) and len(entry_sub_ids) > 1:
                sample = sub_entries[0]
                deduplicated.append({**sample, 'scope': mg_scope, 'scopeLevel': 0,
                                      'consolidatedSubCount': len(entry_sub_ids), 'consolidatedMG': mg_display})
                consolidated = True
                break
        if not consolidated:
            if sub_entries[0]['accessType'] == 'Via Group':
                sample = sub_entries[0]
                deduplicated.append({**sample, 'consolidatedSubCount': len(sub_entries),
                                      'consolidatedMG': f"{len(sub_entries)} subscriptions (multi-MG)"})
            else:
                deduplicated.extend(sub_entries)
    else:
        deduplicated.extend(sub_entries)
    deduplicated.extend(other_entries)

# Enrich with human-readable scope labels
for f in deduplicated:
    f['scopeTypeLabel'] = get_scope_type_label(f['scopeLevel'])
    f['subscriptionOrMG'] = f.get('consolidatedMG') or get_subscription_name(f['scope'], sub_names)

deduplicated.sort(key=lambda x: (x['role'], x['scopeLevel'], x['upn']))

with open(findings_file, 'w') as fh:
    json.dump(deduplicated, fh, indent=2)

unique_users = set(e['upn'] for e in deduplicated)
direct_count = len([e for e in deduplicated if e['accessType'] == 'Direct'])
group_count = len([e for e in deduplicated if e['accessType'] == 'Via Group'])
print(f"  Unique humans with privileged access: {len(unique_users)}")
print(f"  Total findings: {len(deduplicated)} (direct: {direct_count}, via group: {group_count})")
PROCESS_PY

echo ""

# =============================================================================
# Build Slack notification
# =============================================================================
echo "Building Slack notification..."

FINDING_COUNT=$(python3 -c "import json; d=json.load(open('$FINDINGS_JSON')); print(len(d))")
UNIQUE_USERS=$(python3 -c "import json; d=json.load(open('$FINDINGS_JSON')); print(len(set(e['upn'] for e in d)))")
CLEANUP_REMOVED=0
CLEANUP_GROUP_REMOVED=0
if [[ "$removeDirect" == true && -f "$CLEANUP_REMOVED_FILE" ]]; then
    CLEANUP_REMOVED=$(cat "$CLEANUP_REMOVED_FILE")
fi
if [[ "$removeDirect" == true && -f "$CLEANUP_GROUP_REMOVED_FILE" ]]; then
    CLEANUP_GROUP_REMOVED=$(cat "$CLEANUP_GROUP_REMOVED_FILE")
fi
CLEANUP_SUMMARY="Removed $CLEANUP_REMOVED unapproved direct user assignment(s) and $CLEANUP_GROUP_REMOVED group membership(s); group role assignments were not changed."

if [[ "$FINDING_COUNT" -eq 0 ]]; then
    MESSAGE="Scope: CFT/Crime/Heritage/Platform/SDS/SPS Production MGs + HMCTS-SOC-PROD | All assignments are within approved exceptions."
    NO_FINDING_HEADER=":green_circle: Production Privileged Role Audit — No violations found"
    if [[ "$removeDirect" == true ]]; then
        MESSAGE="Scope: CFT/Crime/Heritage/Platform/SDS/SPS Production MGs + HMCTS-SOC-PROD | $CLEANUP_SUMMARY"
        NO_FINDING_HEADER=":green_circle: Production Privileged Role Audit — No remaining violations found"
    fi
    recordNotification "$slackBotToken" "$slackChannelName" \
        "$NO_FINDING_HEADER" \
        "$MESSAGE"
    echo "No findings — green report saved for final reporting."
    if [[ -s "$CLEANUP_FAILURES_FILE" ]]; then
        echo "ERROR: Some privileged access could not be removed; see details above." >&2
        exit 1
    fi
    exit 0
fi

STATUS=":red_circle:"
HEADER="$STATUS Production Privileged Role Audit — $UNIQUE_USERS user(s) with privileged access found ($FINDING_COUNT finding(s))"
SUBHEADING="Scope: CFT/Crime/Heritage/Platform/SDS/SPS Production MGs + HMCTS-SOC-PROD | Exceptions: scripts/prod_audit_exceptions.yaml"
if [[ "$removeDirect" == true ]]; then
    SUBHEADING="$SUBHEADING | $CLEANUP_SUMMARY"
fi

recordNotification "$slackBotToken" "$slackChannelName" "$HEADER" "$SUBHEADING"

# Build the findings message, chunked into <=3900-char thread replies
python3 - "$FINDINGS_JSON" << 'SLACK_MSG_PY'
import json
import sys

findings_file = sys.argv[1]

with open(findings_file, 'r') as f:
    findings = json.load(f)

lines = []
for e in findings:
    upn = e.get('upn', '')
    display = e.get('displayName', '')
    role = e.get('role', '')
    access_type = e.get('accessType', '')
    group_name = e.get('groupName', '')
    scope_type = e.get('scopeTypeLabel', '')
    sub_or_mg = e.get('subscriptionOrMG', '')

    name_part = f"*{display}* (`{upn}`)" if display and display.lower() not in upn.lower() else f"`{upn}`"
    group_part = f" via _{group_name}_" if group_name else ""
    line = f":small_red_triangle: {name_part} — {role} ({access_type}{group_part}) on {scope_type}: _{sub_or_mg}_"
    lines.append(line)

# Split into chunks of ~3900 chars (Slack message limit is ~4000)
chunks = []
current = []
current_len = 0
for line in lines:
    if current_len + len(line) + 1 > 3900 and current:
        chunks.append('\n'.join(current))
        current = [line]
        current_len = len(line)
    else:
        current.append(line)
        current_len += len(line) + 1
if current:
    chunks.append('\n'.join(current))

# Write chunk files
import os
work_dir = os.path.dirname(findings_file)
for i, chunk in enumerate(chunks):
    with open(f"{work_dir}/slack_chunk_{i}.txt", 'w') as fh:
        fh.write(chunk)

with open(f"{work_dir}/chunk_count.txt", 'w') as fh:
    fh.write(str(len(chunks)))
SLACK_MSG_PY

CHUNK_COUNT=$(cat "$WORK_DIR/chunk_count.txt")
for i in $(seq 0 $((CHUNK_COUNT - 1))); do
    CHUNK_MSG=$(cat "$WORK_DIR/slack_chunk_${i}.txt")
    recordThreadResponse "$slackBotToken" "$slackChannelName" "$CHUNK_MSG" "$TS"
done

echo "Report saved for final reporting. ($FINDING_COUNT findings across $UNIQUE_USERS users)"
if [[ -s "$CLEANUP_FAILURES_FILE" ]]; then
    echo "ERROR: Some privileged access could not be removed; see details above." >&2
    exit 1
fi
