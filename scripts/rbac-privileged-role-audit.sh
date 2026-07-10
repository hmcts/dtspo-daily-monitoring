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

usage(){
>&2 cat << EOF
    ------------------------------------------------
    Azure Production Privileged Role Audit
    ------------------------------------------------
    Usage: $0
        [ -t | --slackBotToken ]
        [ -c | --slackChannelName ]
        [ -h | --help ]
EOF
exit 1
}

args=$(getopt -a -o t:c:h --long slackBotToken:,slackChannelName:,help -- "$@")
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
        --) shift; break ;;
        *) >&2 echo Unsupported option: $1
            usage ;;
    esac
done

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

echo "============================================================================="
echo "Azure Production Privileged Role Audit"
echo "============================================================================="

# =============================================================================
# Step 1: Write privileged role definitions
# =============================================================================
echo "[Step 1/4] Loading privileged role definitions..."

cat > "$PRIVILEGED_ROLES_FILE" << 'PRIV_ROLES_JSON'
{
  "roles": {
    "8e3af657-a8ff-443c-a75c-2fe8c4bcb635": { "roleName": "Owner",                                          "roleType": "BuiltInRole" },
    "b24988ac-6180-42a0-ab88-20f7382dd24c": { "roleName": "Contributor",                                    "roleType": "BuiltInRole" },
    "18d7d88d-d35e-4fb5-a5c3-7773c20a72d9": { "roleName": "User Access Administrator",                      "roleType": "BuiltInRole" },
    "f58310d9-a9f6-439a-9e8d-f62e7b41a168": { "roleName": "Role Based Access Control Administrator",        "roleType": "BuiltInRole" },
    "76cc9ee4-d5d3-4a45-a930-26add3d73475": { "roleName": "Access Review Operator Service Principal",       "roleType": "BuiltInRole" }
  }
}
PRIV_ROLES_JSON

echo "  Roles loaded."
echo ""

# =============================================================================
# Step 2: Resolve management group IDs and child subscriptions
# =============================================================================
echo "[Step 2/4] Resolving management groups and child subscriptions..."

az rest --method GET \
    --uri "https://management.azure.com/providers/Microsoft.Management/managementGroups?api-version=2020-05-01" \
    -o json > "$WORK_DIR/all_management_groups_rest.json" 2>/dev/null || echo '{"value":[]}' > "$WORK_DIR/all_management_groups_rest.json"

jq '[.value[] | {name: .name, displayName: .properties.displayName}]' \
    "$WORK_DIR/all_management_groups_rest.json" > "$WORK_DIR/all_management_groups.json"

python3 - "$WORK_DIR/all_management_groups.json" << 'RESOLVE_MG_PY'
import json
import sys
import subprocess

mg_file = sys.argv[1]

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
    except Exception as e:
        mg_subscriptions[display_name] = []
        print(f"    ERROR: {e}")

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
except Exception as e:
    print(f"  ERROR resolving HMCTS-SOC-PROD: {e}")

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

python3 - "$WORK_DIR/resolved_scope.json" "$RAW_ASSIGNMENTS_FILE" "$PRIVILEGED_ROLES_FILE" << 'QUERY_PY'
import json
import sys
import subprocess

scope_file = sys.argv[1]
output_file = sys.argv[2]
privileged_roles_file = sys.argv[3]

with open(privileged_roles_file, 'r') as f:
    priv_data = json.load(f)

PRIVILEGED_ROLE_GUIDS = {}
for role_id, role_info in priv_data.get('roles', {}).items():
    PRIVILEGED_ROLE_GUIDS[role_id] = role_info.get('roleName', role_id)

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
             '--query', "[?principalType=='User' || principalType=='Group'].{principalId:principalId,principalType:principalType,roleDefinitionName:roleDefinitionName,roleDefinitionId:roleDefinitionId,scope:scope}",
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
    except Exception as e:
        print(f"      ERROR: {e}")

print(f"\n  Querying {len(all_sub_ids)} subscriptions...")
for i, sub_id in enumerate(all_sub_ids):
    if (i + 1) % 10 == 0 or i == 0:
        print(f"    Progress: {i + 1}/{len(all_sub_ids)}")
    try:
        result = subprocess.run(
            ['az', 'role', 'assignment', 'list',
             '--all',
             '--subscription', sub_id,
             '--query', "[?principalType=='User' || principalType=='Group'].{principalId:principalId,principalType:principalType,roleDefinitionName:roleDefinitionName,roleDefinitionId:roleDefinitionId,scope:scope}",
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
        pass

# Deduplicate by (principalId, roleDefinitionId, scope)
seen = set()
unique_assignments = []
for a in all_assignments:
    key = (a.get('principalId', ''), a.get('roleDefinitionId', ''), a.get('scope', ''))
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

python3 - "$RAW_ASSIGNMENTS_FILE" "$FINDINGS_JSON" "$PRIVILEGED_ROLES_FILE" "$WORK_DIR/resolved_scope.json" "$EXCEPTIONS_FILE" << 'PROCESS_PY'
import json
import sys
import subprocess
import re
from collections import defaultdict

raw_file = sys.argv[1]
findings_file = sys.argv[2]
privileged_roles_file = sys.argv[3]
scope_file = sys.argv[4]
exceptions_file = sys.argv[5]

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
    result = {'excluded_subscriptions': [], 'allowed_assignments': []}
    try:
        with open(path, 'r') as f:
            lines = f.readlines()
    except FileNotFoundError:
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
            if current_section == 'excluded_subscriptions':
                result['excluded_subscriptions'].append(value)
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
print(f"  Exceptions: {len(exceptions.get('excluded_subscriptions', []))} excluded subscriptions, "
      f"{len(exceptions.get('allowed_assignments', []))} allowed assignments")

excluded_sub_names = set(s.lower() for s in exceptions.get('excluded_subscriptions', []))

sub_names = {}
sub_ids_by_name = {}
try:
    result = subprocess.run(
        ['az', 'account', 'list', '--query', "[].{id:id,name:name}", '-o', 'json'],
        capture_output=True, text=True, timeout=30
    )
    if result.returncode == 0:
        for s in json.loads(result.stdout):
            sid = s['id'].split('/')[-1] if '/' in s['id'] else s['id']
            sub_names[sid] = s['name']
            sub_ids_by_name[s['name'].lower()] = sid
except:
    pass

excluded_sub_ids = set()
for name in excluded_sub_names:
    sid = sub_ids_by_name.get(name)
    if sid:
        excluded_sub_ids.add(sid)
    else:
        excluded_sub_ids.add(name)

def is_excluded_scope(scope):
    m = re.search(r'/subscriptions/([^/]+)', scope, re.IGNORECASE)
    return bool(m and m.group(1) in excluded_sub_ids)

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
        scope_match = scope.lower().rstrip('/').startswith(exc_scope.lower())
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
            user_info[uid] = {'upn': info.get('upn', uid), 'displayName': info.get('displayName', '')}
        else:
            user_info[uid] = {'upn': uid, 'displayName': ''}
    except:
        user_info[uid] = {'upn': uid, 'displayName': ''}

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
    result = subprocess.run(
        ['az', 'rest', '--method', 'GET', '--url', url],
        capture_output=True, text=True, timeout=120
    )
    if result.returncode == 0:
        audit_data = json.loads(result.stdout)
        group_ids_set = set(g.lower() for g in group_ids)
        entries = audit_data.get('value', [])
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
                    added_user_id = tr.get('id')
            if matched_group_id and added_user_id:
                recently_added_to_group.add((matched_group_id, added_user_id))
        print(f"  Members added to in-scope groups in last 25h: {len(recently_added_to_group)}")
    else:
        print(f"  WARNING: Audit log query failed (exit {result.returncode}): {result.stderr[:300]}")
except Exception as e:
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
        'accessType': 'Direct', 'groupName': '',
    })

for a in group_assignments:
    gid = a.get('principalId', '')
    gname = group_info.get(gid, gid)
    role = a.get('resolvedRoleName', a.get('roleDefinitionName', ''))
    scope = a.get('scope', '')
    for m in group_members.get(gid, []):
        if (gid.lower(), m['id'].lower()) in recently_added_to_group:
            continue
        if is_allowed_exception(m['upn'], m['displayName'], role, scope, gname):
            continue
        findings.append({
            'upn': m['upn'], 'displayName': m['displayName'], 'principalId': m['id'],
            'role': role, 'scope': scope, 'scopeLevel': get_scope_level(scope),
            'accessType': 'Via Group', 'groupName': gname,
        })

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

if [[ "$FINDING_COUNT" -eq 0 ]]; then
    slackNotification "$slackBotToken" "$slackChannelName" \
        ":green_circle: Production Privileged Role Audit — No violations found" \
        "Scope: CFT/Crime/Heritage/Platform/SDS/SPS Production MGs + HMCTS-SOC-PROD | All assignments are within approved exceptions."
    echo "No findings — green notification sent."
    exit 0
fi

STATUS=":red_circle:"
HEADER="$STATUS Production Privileged Role Audit — $UNIQUE_USERS user(s) with privileged access found ($FINDING_COUNT finding(s))"
SUBHEADING="Scope: CFT/Crime/Heritage/Platform/SDS/SPS Production MGs + HMCTS-SOC-PROD | Exceptions: scripts/prod_audit_exceptions.yaml"

slackNotification "$slackBotToken" "$slackChannelName" "$HEADER" "$SUBHEADING"

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
    slackThreadResponse "$slackBotToken" "$slackChannelName" "$CHUNK_MSG" "$TS"
done

echo "Slack notification sent. ($FINDING_COUNT findings across $UNIQUE_USERS users)"
