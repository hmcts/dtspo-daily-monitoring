# Azure Privileged RBAC Role Audit Script
# Purpose: Identify all principals (users, service principals, managed identities, groups)
#          with priv admin roles directly assigned, inherited via active group
#          membership/ownership, or held as PIM-eligible group membership/ownership
# Scope: All non-sandbox subscriptions
# Excludes: Sandbox environments

set -e

# Remove all ASCII control characters that can break JSON parsing in jq.
sanitize_json() {
    python3 -c "import sys,re; sys.stdout.write(re.sub(r'[\\x00-\\x1f]', '', sys.stdin.read()))"
}

# Resolve a per-call timeout command: GNU coreutils `timeout` (Linux CI agent) or
# `gtimeout` (macOS via Homebrew coreutils). Empty if neither exists, in which case
# calls run without a hard cap rather than failing outright.
TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_BIN="gtimeout"
fi

# Per-call hard timeout (seconds) and attempt count for each `az` call. ARM/Graph
# throttling (429s) and truncated paging on large subscriptions are transient, so a
# bounded retry recovers them; a hard timeout converts a hung call into a clean,
# retryable failure instead of blocking a worker. Tunable via env.
AZ_TIMEOUT="${RBAC_AZ_TIMEOUT:-150}"
case "$AZ_TIMEOUT" in ''|*[!0-9]*) AZ_TIMEOUT=150 ;; esac
AZ_RETRIES="${RBAC_AZ_RETRIES:-3}"
case "$AZ_RETRIES" in ''|*[!0-9]*) AZ_RETRIES=3 ;; esac
[[ "$AZ_RETRIES" -lt 1 ]] && AZ_RETRIES=1

# with_az_retry <stderr-file> <az command...>: run an `az` call under a per-attempt
# hard timeout with bounded exponential backoff + jitter, echoing the stdout of the
# first attempt whose output parses as JSON (after control-char sanitisation). The
# backoff (5s -> 15s -> 45s, plus 0-5s random jitter) lets a throttling window clear
# WITHOUT every parallel worker retrying in lockstep (which would re-trigger the
# same 429). A PERMANENT failure (no RBAC permission, or subscription not found/
# disabled/not in tenant) short-circuits immediately: retrying it cannot help and
# would only waste minutes of backoff per subscription. Only transient failures
# (throttling, truncated paging, timeouts -- which leave no recognisable error)
# are retried. On total failure it echoes the last (unparseable) output and returns
# 1, leaving the latest stderr in <stderr-file> for classify_az_failure to interpret.
# (classify_az_failure is defined later in the file; bash resolves it at call time,
# and with_az_retry only runs from audit_subscription, well after that definition.)
with_az_retry() {
    local errfile="$1"; shift
    local attempt=1 out="" delay=5 jitter=0
    while [[ "$attempt" -le "$AZ_RETRIES" ]]; do
        if [[ -n "$TIMEOUT_BIN" ]]; then
            out=$("$TIMEOUT_BIN" "$AZ_TIMEOUT" "$@" 2>"$errfile" || true)
        else
            out=$("$@" 2>"$errfile" || true)
        fi
        if printf '%s' "$out" | sanitize_json | jq -e . >/dev/null 2>&1; then
            printf '%s' "$out"
            return 0
        fi
        # Don't burn retries on a permanent failure -- it will fail identically.
        case "$(classify_az_failure "$errfile")" in
            "no permissions"*|"no access"*)
                printf '%s' "$out"
                return 1
                ;;
        esac
        if [[ "$attempt" -lt "$AZ_RETRIES" ]]; then
            jitter=$((RANDOM % 6))
            sleep "$((delay + jitter))"
            delay=$((delay * 3))
        fi
        attempt=$((attempt + 1))
    done
    printf '%s' "$out"
    return 1
}

# Read all pages from a Microsoft Graph collection endpoint and return one JSON array.
graph_list_all() {
    local url="$1"
    local tmp_file=""
    local response=""
    local next_link=""

    tmp_file="$(mktemp)"
    next_link="$url"

    while [[ -n "$next_link" ]]; do
        response=$(az rest --method GET --url "$next_link" -o json 2>/dev/null | sanitize_json || echo '{"value":[]}')
        if ! echo "$response" | jq -e . >/dev/null 2>&1; then
            rm -f "$tmp_file"
            echo "[]"
            return 0
        fi

        echo "$response" | jq -c '.value[]?' >> "$tmp_file"
        next_link=$(echo "$response" | jq -r '."@odata.nextLink" // empty')
    done

    if [[ -s "$tmp_file" ]]; then
        jq -s '.' "$tmp_file"
    else
        echo "[]"
    fi
    rm -f "$tmp_file"
}

# Emit an inherited effective-permission row once per unique key.
emit_inherited_row_once() {
    local dedupe_file="$1"
    local dedupe_key="$2"
    local principal_id="$3"
    local role_def_id="$4"
    local display_name="$5"
    local identifier="$6"
    local identity_type="$7"
    local role_name="$8"
    local duration_type="$9"
    local expires_on="${10}"
    local scope="${11}"
    local scope_type="${12}"
    local sub_name="${13}"
    local sub_id="${14}"
    local assignment_id="${15}"
    local assignment_source="${16}"
    local inherited_group_id="${17}"
    local inherited_group_name="${18}"

    if grep -Fqx "$dedupe_key" "$dedupe_file" 2>/dev/null; then
        return 0
    fi
    echo "$dedupe_key" >> "$dedupe_file"

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$(csv_field "$principal_id")" \
        "$(csv_field "$role_def_id")" \
        "$(csv_field "$display_name")" \
        "$(csv_field "$identifier")" \
        "$(csv_field "$identity_type")" \
        "$(csv_field "$role_name")" \
        "$(csv_field "$duration_type")" \
        "$(csv_field "$expires_on")" \
        "$(csv_field "$scope")" \
        "$(csv_field "$scope_type")" \
        "$(csv_field "$sub_name")" \
        "$(csv_field "$sub_id")" \
        "$(csv_field "$assignment_id")" \
        "$(csv_field "$assignment_source")" \
        "$(csv_field "$inherited_group_id")" \
        "$(csv_field "$inherited_group_name")" \
        >> "$OUTPUT_FILE"
}

# Escape any commas or double-quotes in fields for CSV safety.
csv_field() { echo "$1" | sed 's/"/""/g' | awk '{print "\"" $0 "\"";}'; }

echo "=========================================="
echo "Azure RBAC Privileged Access Audit - All Subscriptions"
echo "=========================================="
echo ""

# Output file (timestamped snapshot; overridable for CI / pipeline artifacts)
OUTPUT_FILE=""
OUTPUT_DIR=""
# Entra tenant IDs to restrict the audit to (empty => every tenant in the CLI cache).
TENANT_FILTER=()
# Subscription names or IDs to restrict the audit to (empty => all in-scope subs).
# Mainly for testing: target a single small subscription instead of the full estate.
SUBSCRIPTION_FILTER=()

usage() {
    cat >&2 <<EOF
Usage: $0 [--outputFile <path>] [--outputDir <dir>] [--tenant <id[,id,...]>] [--subscription <name|id[,...]>]
  --outputFile <path>  Full path to write the CSV snapshot
  --outputDir  <dir>   Directory to write rbac-snapshot-<YYYY-MM-DDTHHMMSSZ>.csv into
                       (default: current directory)
  -t, --tenant <id[,id,...]>
                       Restrict the audit to subscriptions in these Entra tenant
                       IDs. Repeatable and/or comma-separated. Without it, EVERY
                       tenant in the Azure CLI's cached logins is audited.
  -s, --subscription <name|id[,name|id,...]>
                       Restrict the audit to these subscriptions, matched on name
                       OR id (case-insensitive). Repeatable and/or comma-separated.
                       Useful for targeting one small subscription when testing.
  -h, --help           Show this help
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--outputFile) OUTPUT_FILE="$2"; shift 2 ;;
        -d|--outputDir)  OUTPUT_DIR="$2"; shift 2 ;;
        -t|--tenant|--tenants)
            # Accept comma-separated lists and allow the flag to be repeated.
            IFS=',' read -r -a _tlist <<< "$2"
            for _t in "${_tlist[@]}"; do
                _t="$(printf '%s' "$_t" | tr -d '[:space:]')"
                [[ -n "$_t" ]] && TENANT_FILTER+=("$_t")
            done
            shift 2 ;;
        -s|--subscription|--subscriptions)
            # Accept comma-separated lists and allow the flag to be repeated.
            IFS=',' read -r -a _slist <<< "$2"
            for _s in "${_slist[@]}"; do
                # Trim surrounding whitespace only (names may contain internal spaces).
                _s="$(printf '%s' "$_s" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
                [[ -n "$_s" ]] && SUBSCRIPTION_FILTER+=("$_s")
            done
            shift 2 ;;
        -h|--help)       usage ;;
        *) echo "Unknown option: $1" >&2; usage ;;
    esac
done

if [[ -z "$OUTPUT_FILE" ]]; then
    OUTPUT_DIR="${OUTPUT_DIR:-.}"
    mkdir -p "$OUTPUT_DIR"
    OUTPUT_FILE="${OUTPUT_DIR}/rbac-snapshot-$(date -u +%Y-%m-%dT%H%M%SZ).csv"
fi

# Privileged roles to search for
PRIVILEGED_ROLES=(
"owner"
"contributor"
"Access Review Operator Service Role"
"Anyscale Platform Administrator Role"
"Azure Contributor Role minus deletes"
"PIM Azure Contributor"
"Reservations Administrator"
"Role Based Access Control Administrator"
"Service Group Administrator"
"Service Group Contributor"
"User Access Administrator"
)

# Lowercased copy for case-insensitive role matching. Azure returns canonical
# role names ("Owner", "Contributor", ...), but the list above may be typed in
# any case; without this, lowercase entries like "owner" match nothing and those
# assignments (and their group expansions) are silently dropped from the audit.
PRIVILEGED_ROLES_LC=()
for _priv_role in "${PRIVILEGED_ROLES[@]}"; do
    PRIVILEGED_ROLES_LC+=("$(printf '%s' "$_priv_role" | tr '[:upper:]' '[:lower:]')")
done

# Ensure logged in (non-interactive; in CI run inside an AzureCLI@2 task)
echo "Verifying Azure login..."
if ! az account show > /dev/null 2>&1; then
    echo "Error: not authenticated to Azure. Run 'az login' locally, or execute this script inside an AzureCLI@2 task in CI." >&2
    exit 1
fi

echo ""

# Build a JSON array of requested tenant IDs (empty => no tenant filter).
if [[ ${#TENANT_FILTER[@]} -gt 0 ]]; then
    TENANTS_JSON=$(printf '%s\n' "${TENANT_FILTER[@]}" | jq -R -s 'split("\n") | map(select(length>0))')
    echo "Fetching subscriptions restricted to tenant(s): ${TENANT_FILTER[*]}"
else
    TENANTS_JSON='[]'
    echo "Fetching subscriptions from ALL cached tenant logins..."
    echo "  WARNING: no --tenant given, so every tenant in the Azure CLI cache is in scope." >&2
    echo "           'az account list' merges all logins; pass --tenant <id[,id,...]> to bound the" >&2
    echo "           audit to known Entra tenants (recommended for a security control)." >&2
fi

# Build a JSON array of requested subscription names/ids, lower-cased for
# case-insensitive matching (empty => no subscription filter).
if [[ ${#SUBSCRIPTION_FILTER[@]} -gt 0 ]]; then
    SUBS_FILTER_JSON=$(printf '%s\n' "${SUBSCRIPTION_FILTER[@]}" | jq -R -s 'split("\n") | map(select(length>0) | ascii_downcase)')
    echo "Restricting to subscription(s): ${SUBSCRIPTION_FILTER[*]}"
else
    SUBS_FILTER_JSON='[]'
fi

# Enumerate subscriptions, then filter by name (exclude sandbox) and tenant in jq,
# where --argjson keeps tenant-ID quoting safe. This is where cross-tenant bleed is
# prevented: only subscriptions whose tenantId is in the requested set are kept.
# Also drop the Azure CLI's synthetic "tenant level account" placeholder, which it
# injects when the identity has tenant/management-group access but no concrete
# subscription: its id equals the tenantId (real subscription IDs never do) and it
# is named "N/A(tenant level account)". Auditing it just yields a permanent,
# un-retryable SubscriptionNotFound coverage failure every run.
SUBSCRIPTIONS=$(az account list -o json 2>/dev/null | sanitize_json | jq -c --argjson tenants "$TENANTS_JSON" --argjson subs "$SUBS_FILTER_JSON" '
    [ .[]
      | { id: .id, name: .name, tenantId: .tenantId }
      | select(.id != .tenantId)
      | select((.name | ascii_downcase | contains("tenant level account")) | not)
      | select((.name | ascii_downcase | (contains("sandbox") or contains("sbox"))) | not)
      | select((($tenants | length) == 0) or (.tenantId as $tid | ($tenants | index($tid)) != null))
      | select((($subs | length) == 0) or (.id | ascii_downcase) as $sid | (.name | ascii_downcase) as $sname | ($subs | index($sid)) != null or ($subs | index($sname)) != null)
    ]' || echo "")

if ! echo "$SUBSCRIPTIONS" | jq -e . >/dev/null 2>&1; then
    echo "Error: unable to parse subscription list as JSON after sanitization"
    exit 1
fi

SUBSCRIPTION_COUNT=$(echo "$SUBSCRIPTIONS" | jq '. | length')

# Distinct tenants actually in scope (recorded in the manifest; also drives the
# multi-tenant caveat below).
AUDITED_TENANTS_JSON=$(echo "$SUBSCRIPTIONS" | jq -c '[.[].tenantId] | unique' 2>/dev/null || echo "[]")
DISTINCT_TENANTS=$(echo "$AUDITED_TENANTS_JSON" | jq 'length' 2>/dev/null || echo 0)

if [[ "${SUBSCRIPTION_COUNT:-0}" -eq 0 ]]; then
    if [[ ${#TENANT_FILTER[@]} -gt 0 ]]; then
        echo "Error: no subscriptions found for the requested tenant(s): ${TENANT_FILTER[*]}." >&2
        echo "       Verify the tenant IDs and that you are logged in to each (az login --tenant <id>)." >&2
    elif [[ ${#SUBSCRIPTION_FILTER[@]} -gt 0 ]]; then
        echo "Error: no subscriptions matched the requested --subscription filter: ${SUBSCRIPTION_FILTER[*]}." >&2
        echo "       Verify the subscription name(s)/id(s) and that they are not sandbox-excluded." >&2
    else
        echo "Error: no subscriptions found in the current Azure CLI login." >&2
    fi
    exit 1
fi

echo "Found $SUBSCRIPTION_COUNT non-sandbox subscription(s) across ${DISTINCT_TENANTS} tenant(s) to audit"

if [[ "${DISTINCT_TENANTS:-0}" -gt 1 ]]; then
    echo "  NOTE: subscriptions span ${DISTINCT_TENANTS} tenants. Group membership/owner expansion and" >&2
    echo "        PIM-eligible collection resolve against the ACTIVE login's tenant, so effective-access" >&2
    echo "        rows for groups/PIM in OTHER tenants may be incomplete. For full fidelity run once per" >&2
    echo "        tenant, or ensure the audit identity has directory read in every in-scope tenant." >&2
fi
echo ""

echo "Starting audit..."
echo ""

# Write CSV header
echo "PrincipalId,RoleDefinitionId,DisplayName,Identifier,IdentityType,RoleName,DurationType,ExpiresOn,Scope,ScopeType,SubscriptionName,SubscriptionId,AssignmentId,AssignmentSource,InheritedFromGroupId,InheritedFromGroupName" > "$OUTPUT_FILE"

# De-dup effective inherited rows (Bash 3.2-safe; no associative arrays).
INHERITED_DEDUPE_FILE="$(mktemp)"

# PIM (Privileged Identity Management) *eligible* group memberships are NOT
# returned by /transitiveMembers or /owners -- those list only ACTIVE
# assignments. Eligible (activate-on-demand) members are exactly the blind spot
# that hides "user added to a highly privileged admin group". Read them from the
# privilegedAccess eligibility API once for the whole tenant, then look up per
# group during expansion.
PIM_ELIGIBILITY_FILE="$(mktemp)"
echo "[]" > "$PIM_ELIGIBILITY_FILE"
PIM_READ_OK=true

# Coverage tracking for snapshot integrity (C2): record which subscriptions were
# audited end-to-end vs. which failed, so a silently truncated snapshot (e.g. a
# subscription we lost Reader on, or a transient az error) is detectable
# downstream instead of masquerading as a wave of legitimate role removals.
COVERAGE_OK_FILE="$(mktemp)"      # one SubscriptionId per line: audited OK
COVERAGE_FAIL_FILE="$(mktemp)"    # "SubscriptionId|SubscriptionName" per line: failed

# Per-worker scratch for the parallel subscription audit: one rows/dedupe/log
# file per subscription, merged into the snapshot after all workers finish.
WORK_DIR="$(mktemp -d)"

# Max subscriptions to audit concurrently. Bounded to limit Azure CLI / Microsoft
# Graph throttling (429s would otherwise silently thin out group expansions) and
# to avoid starving the CI agent of CPU/memory/network (too many concurrent `az`
# workers can make the DevOps agent miss heartbeats and drop the job). Default 2
# (lowered from 4): concurrency is the dominant driver of per-call throttling, so a
# smaller pool raises the per-attempt success rate far more than retries alone.
# Override with RBAC_MAX_PARALLEL.
MAX_PARALLEL="${RBAC_MAX_PARALLEL:-2}"
case "$MAX_PARALLEL" in ''|*[!0-9]*) MAX_PARALLEL=2 ;; esac
[[ "$MAX_PARALLEL" -lt 1 ]] && MAX_PARALLEL=1

cleanup() {
    rm -f "$INHERITED_DEDUPE_FILE" "$PIM_ELIGIBILITY_FILE" "$COVERAGE_OK_FILE" "$COVERAGE_FAIL_FILE"
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

echo "Fetching PIM eligible group memberships (one-time)..."
# Pre-flight: detect a missing Graph permission up front so the gap is loud, not
# silently swallowed (the per-call helper hides errors behind an empty array).
PIM_PREFLIGHT_ERR="$(az rest --method GET \
    --url "https://graph.microsoft.com/v1.0/identityGovernance/privilegedAccess/group/eligibilityScheduleInstances?\$top=1" \
    -o json 2>&1 >/dev/null || true)"
if [[ -n "$PIM_PREFLIGHT_ERR" ]]; then
    PIM_READ_OK=false
    echo "  WARNING: cannot read PIM eligible group memberships; eligible (not-yet-activated)" >&2
    echo "           members/owners of privileged groups will be MISSING from this snapshot." >&2
    echo "           Grant the audit identity the Microsoft Graph application permission" >&2
    echo "           'PrivilegedAccess.Read.AzureADGroup' (or 'PrivilegedEligibilitySchedule.Read.AzureADGroup')" >&2
    echo "           and admin-consent it to close this gap." >&2
    echo "           Underlying error: $(echo "$PIM_PREFLIGHT_ERR" | head -1)" >&2
else
    graph_list_all "https://graph.microsoft.com/v1.0/identityGovernance/privilegedAccess/group/eligibilityScheduleInstances?\$expand=principal" > "$PIM_ELIGIBILITY_FILE"
    echo "  Collected $(jq 'length' "$PIM_ELIGIBILITY_FILE" 2>/dev/null || echo 0) eligible group assignment(s)."
fi

# Counter for progress
CURRENT=0
TOTAL_FINDINGS=0

# classify_az_failure <stderr-file>: turn a failed `az role assignment list` into
# a short human reason so the operator can tell a permissions gap (the audit
# identity lacks RBAC read) apart from an access gap (subscription gone/disabled/
# not visible to this tenant). Falls back to 'unknown' when az emitted nothing.
classify_az_failure() {
    local errfile="$1" msg=""
    [[ -f "$errfile" ]] && msg=$(tr '[:upper:]' '[:lower:]' < "$errfile")
    if [[ "$msg" == *"authorizationfailed"* || "$msg" == *"does not have authorization"* || "$msg" == *"forbidden"* || "$msg" == *"insufficient privileges"* ]]; then
        echo "no permissions (audit identity lacks RBAC read)"
    elif [[ "$msg" == *"subscriptionnotfound"* || "$msg" == *"not found"* || "$msg" == *"could not be found"* || "$msg" == *"disabled"* || "$msg" == *"was not found"* ]]; then
        echo "no access (subscription not found/disabled/not in tenant)"
    elif [[ -z "$msg" ]]; then
        echo "unknown (no error output)"
    else
        echo "unknown error"
    fi
}

# Process each subscription
# audit_subscription <sub-json>: audit ONE subscription end-to-end. Designed to
# run in its own forked subshell (see the parallel launcher below), so OUTPUT_FILE
# and INHERITED_DEDUPE_FILE are shadowed to per-subscription temp files and merged
# after all workers join -- concurrent workers never share a writer. Returns 0
# only if the subscription was fully audited; non-zero on any failure so the
# launcher records it as a coverage failure (C2).
audit_subscription() {
    local sub="$1"
    local SUB_ID SUB_NAME OUTPUT_FILE INHERITED_DEDUPE_FILE
    local ASSIGNMENTS TOTAL_ASSIGNMENTS SCHEDULE_INSTANCES

    SUB_ID=$(echo "$sub" | jq -r '.id')
    SUB_NAME=$(echo "$sub" | jq -r '.name')

    # Per-subscription outputs, merged into the snapshot after all workers finish.
    OUTPUT_FILE="${WORK_DIR}/rows.${SUB_ID}.csv"
    INHERITED_DEDUPE_FILE="${WORK_DIR}/dedupe.${SUB_ID}"
    : > "$OUTPUT_FILE"
    : > "$INHERITED_DEDUPE_FILE"

    echo "Processing: $SUB_NAME ($SUB_ID)"

    # Get all role assignments for this subscription at all scopes (all principal
    # types). Pass --subscription explicitly instead of `az account set`, so that
    # parallel workers cannot race on the CLI's global active-subscription state.
    echo "  Fetching role assignments..."
    local AZ_ERR_FILE="${WORK_DIR}/azerr.${SUB_ID}"
    ASSIGNMENTS=$(with_az_retry "$AZ_ERR_FILE" az role assignment list --all --subscription "$SUB_ID" -o json | sanitize_json || echo "")

    if ! echo "$ASSIGNMENTS" | jq -e . >/dev/null 2>&1; then
        local FAIL_REASON
        FAIL_REASON=$(classify_az_failure "$AZ_ERR_FILE")
        printf '%s' "$FAIL_REASON" > "${WORK_DIR}/reason.${SUB_ID}"
        echo "  Warning: could not retrieve/parse role assignments for $SUB_NAME ($SUB_ID); recording audit FAILURE ($FAIL_REASON)."
        return 1
    fi
    
    TOTAL_ASSIGNMENTS=$(echo "$ASSIGNMENTS" | jq '. | length')
    echo "  Found $TOTAL_ASSIGNMENTS assignments, filtering for privileged roles..."

    # Fetch schedule instances to determine permanent vs temporary assignments
    echo "  Fetching assignment schedule data..."
    #double failure failsafe
    SCHEDULE_INSTANCES=$(with_az_retry "${WORK_DIR}/azerr.sched.${SUB_ID}" az rest --method GET \
        --url "https://management.azure.com/subscriptions/$SUB_ID/providers/Microsoft.Authorization/roleAssignmentScheduleInstances?api-version=2020-10-01-preview" \
        -o json \
        | sanitize_json \
        | jq '.value // []' 2>/dev/null || echo "[]")
    
    # Process each assignment
    echo "$ASSIGNMENTS" | jq -c '.[]' | while read -r assignment; do
        ROLE_NAME=$(echo "$assignment" | jq -r '.roleDefinitionName')
        ROLE_NAME_LC=$(printf '%s' "$ROLE_NAME" | tr '[:upper:]' '[:lower:]')

        # Check if this role is in our privileged list (case-insensitive)
        for PRIV_ROLE in "${PRIVILEGED_ROLES_LC[@]}"; do
            if [[ "$ROLE_NAME_LC" == "$PRIV_ROLE" ]]; then
                # Extract assignment details
                PRINCIPAL_ID=$(echo "$assignment" | jq -r '.principalId')
                PRINCIPAL_TYPE=$(echo "$assignment" | jq -r '.principalType')
                SCOPE=$(echo "$assignment" | jq -r '.scope')
                ASSIGNMENT_ID=$(echo "$assignment" | jq -r '.id')
                ROLE_DEF_ID=$(echo "$assignment" | jq -r '.roleDefinitionId')

                # Determine scope type
                if [[ "$SCOPE" == *"/managementGroups/"* ]]; then
                    SCOPE_TYPE="ManagementGroup"
                elif [[ "$SCOPE" == *"/subscriptions/"* ]] && [[ "$SCOPE" != *"/resourceGroups/"* ]]; then
                    SCOPE_TYPE="Subscription"
                elif [[ "$SCOPE" == *"/resourceGroups/"* ]] && [[ "$SCOPE" != *"/providers/"* ]]; then
                    SCOPE_TYPE="ResourceGroup"
                else
                    SCOPE_TYPE="Resource"
                fi

                # Resolve principal details based on type
                if [[ "$PRINCIPAL_TYPE" == "User" ]]; then
                    PRINCIPAL_INFO=$(az ad user show --id "$PRINCIPAL_ID" \
                        --query "{name:displayName, identifier:userPrincipalName}" -o json 2>/dev/null \
                        | sanitize_json \
                        || echo '{"name":"Unknown","identifier":"Unknown"}')
                    IDENTITY_TYPE="User"
                elif [[ "$PRINCIPAL_TYPE" == "ServicePrincipal" ]]; then
                    SP_INFO=$(az ad sp show --id "$PRINCIPAL_ID" \
                        --query "{name:displayName, spType:servicePrincipalType}" -o json 2>/dev/null \
                        | sanitize_json \
                        || echo '{"name":"Unknown","spType":"Unknown"}')
                    SP_SUBTYPE=$(echo "$SP_INFO" | jq -r '.spType')
                    PRINCIPAL_INFO=$(echo "$SP_INFO" | jq '{name: .name, identifier: "N/A"}')
                    if [[ "$SP_SUBTYPE" == "ManagedIdentity" ]]; then
                        IDENTITY_TYPE="ManagedIdentity"
                    else
                        IDENTITY_TYPE="ServicePrincipal"
                    fi
                elif [[ "$PRINCIPAL_TYPE" == "Group" ]]; then
                    GROUP_INFO=$(az ad group show --group "$PRINCIPAL_ID" \
                        --query "{name:displayName}" -o json 2>/dev/null \
                        | sanitize_json \
                        || echo '{"name":"Unknown"}')
                    PRINCIPAL_INFO=$(echo "$GROUP_INFO" | jq '{name: .name, identifier: "N/A"}')
                    IDENTITY_TYPE="Group"
                else
                    PRINCIPAL_INFO='{"name":"Unknown","identifier":"Unknown"}'
                    IDENTITY_TYPE="$PRINCIPAL_TYPE"
                fi

                DISPLAY_NAME=$(echo "$PRINCIPAL_INFO" | jq -r '.name')
                IDENTIFIER=$(echo "$PRINCIPAL_INFO" | jq -r '.identifier')

                # Determine if assignment is permanent or temporary via schedule instances
                SCHEDULE_MATCH=$(echo "$SCHEDULE_INSTANCES" | jq \
                    --arg pid "$PRINCIPAL_ID" \
                    --arg rid "$ROLE_DEF_ID" \
                    --arg scope "$SCOPE" \
                    'first(.[] | select(
                        .properties.principalId == $pid and
                        .properties.roleDefinitionId == $rid and
                        .properties.scope == $scope
                    )) // {}' 2>/dev/null || echo "{}")

                END_DATE=$(echo "$SCHEDULE_MATCH" | jq -r '.properties.endDateTime // empty' 2>/dev/null || echo "")
                ASSIGN_SUBTYPE=$(echo "$SCHEDULE_MATCH" | jq -r '.properties.assignmentType // empty' 2>/dev/null || echo "")

                if [[ -z "$END_DATE" ]]; then
                    DURATION_TYPE="Permanent"
                    EXPIRES_ON=""
                else
                    DURATION_TYPE="Temporary"
                    EXPIRES_ON="$END_DATE"
                fi

                if [[ "$ASSIGN_SUBTYPE" == "Activated" ]]; then
                    DURATION_TYPE="PIM-Activated"
                fi

                echo "  ✓ Found: [$IDENTITY_TYPE] $DISPLAY_NAME → $ROLE_NAME ($DURATION_TYPE${EXPIRES_ON:+, expires: $EXPIRES_ON}) at $SCOPE_TYPE"

                # Write direct-assignment CSV row
                printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
                    "$(csv_field "$PRINCIPAL_ID")" \
                    "$(csv_field "$ROLE_DEF_ID")" \
                    "$(csv_field "$DISPLAY_NAME")" \
                    "$(csv_field "$IDENTIFIER")" \
                    "$(csv_field "$IDENTITY_TYPE")" \
                    "$(csv_field "$ROLE_NAME")" \
                    "$(csv_field "$DURATION_TYPE")" \
                    "$(csv_field "$EXPIRES_ON")" \
                    "$(csv_field "$SCOPE")" \
                    "$(csv_field "$SCOPE_TYPE")" \
                    "$(csv_field "$SUB_NAME")" \
                    "$(csv_field "$SUB_ID")" \
                    "$(csv_field "$ASSIGNMENT_ID")" \
                    "$(csv_field "Direct")" \
                    "$(csv_field "")" \
                    "$(csv_field "")" \
                    >> "$OUTPUT_FILE"

                # Expand group role assignments into effective inherited permissions:
                # 1) transitive members (includes nested groups/users/SPs)
                # 2) group owners
                # 3) PIM-eligible members/owners (active APIs do not list these)
                if [[ "$PRINCIPAL_TYPE" == "Group" ]]; then
                    TRANSITIVE_MEMBERS=$(graph_list_all "https://graph.microsoft.com/v1.0/groups/${PRINCIPAL_ID}/transitiveMembers")
                    GROUP_OWNERS=$(graph_list_all "https://graph.microsoft.com/v1.0/groups/${PRINCIPAL_ID}/owners")

                    if ! echo "$TRANSITIVE_MEMBERS" | jq -e . >/dev/null 2>&1; then
                        echo "  Warning: could not parse transitive members for group '$DISPLAY_NAME' ($PRINCIPAL_ID)"
                    else
                        echo "$TRANSITIVE_MEMBERS" | jq -c '.[]' | while read -r member; do
                            MEMBER_ID=$(echo "$member" | jq -r '.id // empty')
                            [[ -z "$MEMBER_ID" ]] && continue

                            MEMBER_ODATA=$(echo "$member" | jq -r '."@odata.type" // ""')
                            MEMBER_NAME=$(echo "$member" | jq -r '.displayName // "Unknown"')
                            MEMBER_IDENTIFIER="N/A"
                            MEMBER_IDENTITY_TYPE="Unknown"

                            if [[ "$MEMBER_ODATA" == *"user"* ]]; then
                                MEMBER_IDENTITY_TYPE="User"
                                MEMBER_IDENTIFIER=$(echo "$member" | jq -r '.userPrincipalName // "Unknown"')
                            elif [[ "$MEMBER_ODATA" == *"servicePrincipal"* ]]; then
                                MEMBER_IDENTITY_TYPE="ServicePrincipal"
                                MEMBER_IDENTIFIER=$(echo "$member" | jq -r '.appId // "N/A"')
                            elif [[ "$MEMBER_ODATA" == *"group"* ]]; then
                                MEMBER_IDENTITY_TYPE="Group"
                            fi

                            echo "  ↳ Effective(transitive): [$MEMBER_IDENTITY_TYPE] $MEMBER_NAME inherits $ROLE_NAME via group $DISPLAY_NAME"

                            DEDUPE_KEY="${MEMBER_ID}|${ROLE_DEF_ID}|${SCOPE}|transitive|${PRINCIPAL_ID}"
                            emit_inherited_row_once \
                                "$INHERITED_DEDUPE_FILE" \
                                "$DEDUPE_KEY" \
                                "$MEMBER_ID" \
                                "$ROLE_DEF_ID" \
                                "$MEMBER_NAME" \
                                "$MEMBER_IDENTIFIER" \
                                "$MEMBER_IDENTITY_TYPE" \
                                "$ROLE_NAME" \
                                "$DURATION_TYPE" \
                                "$EXPIRES_ON" \
                                "$SCOPE" \
                                "$SCOPE_TYPE" \
                                "$SUB_NAME" \
                                "$SUB_ID" \
                                "${ASSIGNMENT_ID}|via:${PRINCIPAL_ID}" \
                                "InheritedGroupTransitiveMember" \
                                "$PRINCIPAL_ID" \
                                "$DISPLAY_NAME"
                        done
                    fi

                    if ! echo "$GROUP_OWNERS" | jq -e . >/dev/null 2>&1; then
                        echo "  Warning: could not parse owners for group '$DISPLAY_NAME' ($PRINCIPAL_ID)"
                    else
                        echo "$GROUP_OWNERS" | jq -c '.[]' | while read -r owner; do
                            OWNER_ID=$(echo "$owner" | jq -r '.id // empty')
                            [[ -z "$OWNER_ID" ]] && continue

                            OWNER_ODATA=$(echo "$owner" | jq -r '."@odata.type" // ""')
                            OWNER_NAME=$(echo "$owner" | jq -r '.displayName // "Unknown"')
                            OWNER_IDENTIFIER="N/A"
                            OWNER_IDENTITY_TYPE="Unknown"

                            if [[ "$OWNER_ODATA" == *"user"* ]]; then
                                OWNER_IDENTITY_TYPE="User"
                                OWNER_IDENTIFIER=$(echo "$owner" | jq -r '.userPrincipalName // "Unknown"')
                            elif [[ "$OWNER_ODATA" == *"servicePrincipal"* ]]; then
                                OWNER_IDENTITY_TYPE="ServicePrincipal"
                                OWNER_IDENTIFIER=$(echo "$owner" | jq -r '.appId // "N/A"')
                            elif [[ "$OWNER_ODATA" == *"group"* ]]; then
                                OWNER_IDENTITY_TYPE="Group"
                            fi

                            echo "  ↳ Effective(owner): [$OWNER_IDENTITY_TYPE] $OWNER_NAME can control group $DISPLAY_NAME with $ROLE_NAME"

                            DEDUPE_KEY="${OWNER_ID}|${ROLE_DEF_ID}|${SCOPE}|owner|${PRINCIPAL_ID}"
                            emit_inherited_row_once \
                                "$INHERITED_DEDUPE_FILE" \
                                "$DEDUPE_KEY" \
                                "$OWNER_ID" \
                                "$ROLE_DEF_ID" \
                                "$OWNER_NAME" \
                                "$OWNER_IDENTIFIER" \
                                "$OWNER_IDENTITY_TYPE" \
                                "$ROLE_NAME" \
                                "$DURATION_TYPE" \
                                "$EXPIRES_ON" \
                                "$SCOPE" \
                                "$SCOPE_TYPE" \
                                "$SUB_NAME" \
                                "$SUB_ID" \
                                "${ASSIGNMENT_ID}|owner-of:${PRINCIPAL_ID}" \
                                "InheritedGroupOwner" \
                                "$PRINCIPAL_ID" \
                                "$DISPLAY_NAME"
                        done
                    fi

                    # 3) PIM-eligible members/owners, looked up from the one-time
                    #    tenant-wide eligibility collection (keyed by groupId).
                    if [[ "$PIM_READ_OK" == "true" ]]; then
                        ELIGIBLE_FOR_GROUP=$(jq -c --arg gid "$PRINCIPAL_ID" \
                            '[.[] | select(.groupId == $gid)]' "$PIM_ELIGIBILITY_FILE" 2>/dev/null || echo "[]")

                        echo "$ELIGIBLE_FOR_GROUP" | jq -c '.[]' | while read -r inst; do
                            ELIG_ID=$(echo "$inst" | jq -r '.principalId // empty')
                            [[ -z "$ELIG_ID" ]] && continue

                            ELIG_ACCESS=$(echo "$inst" | jq -r '.accessId // "member"')
                            ELIG_ODATA=$(echo "$inst" | jq -r '.principal."@odata.type" // ""')
                            ELIG_NAME=$(echo "$inst" | jq -r '.principal.displayName // "Unknown"')
                            ELIG_IDENTIFIER="N/A"
                            ELIG_IDENTITY_TYPE="Unknown"

                            if [[ "$ELIG_ODATA" == *"user"* ]]; then
                                ELIG_IDENTITY_TYPE="User"
                                ELIG_IDENTIFIER=$(echo "$inst" | jq -r '.principal.userPrincipalName // "Unknown"')
                            elif [[ "$ELIG_ODATA" == *"servicePrincipal"* ]]; then
                                ELIG_IDENTITY_TYPE="ServicePrincipal"
                                ELIG_IDENTIFIER=$(echo "$inst" | jq -r '.principal.appId // "N/A"')
                            elif [[ "$ELIG_ODATA" == *"group"* ]]; then
                                ELIG_IDENTITY_TYPE="Group"
                            fi

                            if [[ "$ELIG_ACCESS" == "owner" ]]; then
                                ELIG_SOURCE="InheritedGroupEligibleOwner"
                                ELIG_VIA="eligible-owner-of"
                            else
                                ELIG_SOURCE="InheritedGroupEligibleMember"
                                ELIG_VIA="eligible-via"
                            fi

                            echo "  ↳ Effective(PIM-eligible $ELIG_ACCESS): [$ELIG_IDENTITY_TYPE] $ELIG_NAME is eligible for $ROLE_NAME via group $DISPLAY_NAME"

                            DEDUPE_KEY="${ELIG_ID}|${ROLE_DEF_ID}|${SCOPE}|${ELIG_SOURCE}|${PRINCIPAL_ID}"
                            emit_inherited_row_once \
                                "$INHERITED_DEDUPE_FILE" \
                                "$DEDUPE_KEY" \
                                "$ELIG_ID" \
                                "$ROLE_DEF_ID" \
                                "$ELIG_NAME" \
                                "$ELIG_IDENTIFIER" \
                                "$ELIG_IDENTITY_TYPE" \
                                "$ROLE_NAME" \
                                "Eligible" \
                                "" \
                                "$SCOPE" \
                                "$SCOPE_TYPE" \
                                "$SUB_NAME" \
                                "$SUB_ID" \
                                "${ASSIGNMENT_ID}|${ELIG_VIA}:${PRINCIPAL_ID}" \
                                "$ELIG_SOURCE" \
                                "$PRINCIPAL_ID" \
                                "$DISPLAY_NAME"
                        done
                    fi
                fi
                
                break
            fi
        done
    done

    # Fully audited this subscription.
    return 0
}

# run_one <sub-json>: launch one subscription audit, buffer its log, and record
# coverage from the worker's exit status (C2) -- success => audited OK, any
# failure => coverage failure, so a silently truncated snapshot is detectable.
run_one() {
    local sub="$1" sid name reason
    sid=$(echo "$sub" | jq -r '.id')
    name=$(echo "$sub" | jq -r '.name')
    if audit_subscription "$sub" > "${WORK_DIR}/log.${sid}" 2>&1; then
        echo "$sid" >> "$COVERAGE_OK_FILE"
    else
        reason=""
        [[ -f "${WORK_DIR}/reason.${sid}" ]] && reason=$(cat "${WORK_DIR}/reason.${sid}")
        echo "${sid}|${name}|${reason}" >> "$COVERAGE_FAIL_FILE"
    fi
}

# Audit subscriptions in parallel to cut wall-clock time, capped at MAX_PARALLEL.
# The subscription list is read from a file (not a pipe) so the loop runs in THIS
# shell and the final `wait` reliably joins every worker before we merge.
echo "Auditing $SUBSCRIPTION_COUNT subscription(s), up to $MAX_PARALLEL in parallel..."
echo ""
SUBS_NDJSON="${WORK_DIR}/subs.ndjson"
echo "$SUBSCRIPTIONS" | jq -c '.[]' > "$SUBS_NDJSON"
LAUNCHED=0
while read -r sub; do
    [[ -z "$sub" ]] && continue
    run_one "$sub" &
    LAUNCHED=$((LAUNCHED + 1))
    if [[ $((LAUNCHED % MAX_PARALLEL)) -eq 0 ]]; then
        wait
    fi
done < "$SUBS_NDJSON"
wait

# --- Retry transient subscription failures -----------------------------------
# Some audits fail for transient reasons (Graph/ARM throttling, a momentary
# connectivity blip) rather than a genuine permission or existence problem.
# Re-attempt any failed subscription a bounded number of times, with a short
# backoff, before finally recording it as a coverage failure. Permanent failures
# (e.g. SubscriptionNotFound) simply fail again and are recorded as before, so
# this never masks a real coverage gap -- it only rescues recoverable ones.
# Override attempts with RBAC_RETRY_ATTEMPTS (0 disables) and the backoff seconds
# with RBAC_RETRY_DELAY.
RETRY_ATTEMPTS="${RBAC_RETRY_ATTEMPTS:-2}"
case "$RETRY_ATTEMPTS" in ''|*[!0-9]*) RETRY_ATTEMPTS=2 ;; esac
RETRY_DELAY="${RBAC_RETRY_DELAY:-15}"
case "$RETRY_DELAY" in ''|*[!0-9]*) RETRY_DELAY=15 ;; esac

RETRY_ROUND=1
while [[ "$RETRY_ATTEMPTS" -gt 0 && -s "$COVERAGE_FAIL_FILE" && "$RETRY_ROUND" -le "$RETRY_ATTEMPTS" ]]; do
    # Snapshot the current failures (ids only), then clear the fail list so this
    # round re-records only those that fail again. Subscriptions that succeed on
    # retry are appended to the OK list by run_one and merged normally.
    RETRY_IDS=$(cut -d'|' -f1 "$COVERAGE_FAIL_FILE")
    RETRY_COUNT=$(printf '%s\n' "$RETRY_IDS" | grep -c . || true)
    : > "$COVERAGE_FAIL_FILE"

    echo ""
    echo "Retry round ${RETRY_ROUND}/${RETRY_ATTEMPTS}: re-auditing ${RETRY_COUNT} failed subscription(s) after ${RETRY_DELAY}s backoff..."
    sleep "$RETRY_DELAY"

    LAUNCHED=0
    while read -r rsid; do
        [[ -z "$rsid" ]] && continue
        # Recover the full subscription JSON for this id from the ndjson list.
        rsub=$(jq -c --arg id "$rsid" 'select(.id == $id)' "$SUBS_NDJSON" | head -n 1)
        if [[ -z "$rsub" ]]; then
            echo "${rsid}|" >> "$COVERAGE_FAIL_FILE"
            continue
        fi
        run_one "$rsub" &
        LAUNCHED=$((LAUNCHED + 1))
        if [[ $((LAUNCHED % MAX_PARALLEL)) -eq 0 ]]; then
            wait
        fi
    done <<< "$RETRY_IDS"
    wait
    RETRY_ROUND=$((RETRY_ROUND + 1))
done

# Print each worker's buffered log in stable subscription order (parallel output
# would otherwise interleave unreadably).
echo "$SUBSCRIPTIONS" | jq -r '.[].id' | while read -r sid; do
    if [[ -f "${WORK_DIR}/log.${sid}" ]]; then
        cat "${WORK_DIR}/log.${sid}"
    fi
done
echo ""

# Merge rows ONLY from subscriptions that completed successfully, so a worker that
# died mid-way cannot leak partial rows into the snapshot (header already written).
while read -r sid; do
    if [[ -n "$sid" && -f "${WORK_DIR}/rows.${sid}.csv" ]]; then
        cat "${WORK_DIR}/rows.${sid}.csv" >> "$OUTPUT_FILE"
    fi
done < "$COVERAGE_OK_FILE"

# Sort data rows deterministically (header preserved) so day-to-day diffs are stable
if [[ -f "$OUTPUT_FILE" ]]; then
    SORTED_TMP="$(mktemp)"
    { head -n 1 "$OUTPUT_FILE"; tail -n +2 "$OUTPUT_FILE" | LC_ALL=C sort; } > "$SORTED_TMP"
    mv "$SORTED_TMP" "$OUTPUT_FILE"
fi

# --- Snapshot coverage manifest (C2) -----------------------------------------
# Written next to the CSV (same stem, .meta.json) and published with it. The
# change monitor reads this to tell a genuinely shrunken snapshot apart from one
# that is merely incomplete, and to alert on lost subscription coverage rather
# than reporting the missing rows as ordinary removals.
META_FILE="${OUTPUT_FILE%.csv}.meta.json"

AUDITED_IDS_JSON=$(jq -R -s 'split("\n") | map(select(length>0))' "$COVERAGE_OK_FILE" 2>/dev/null || echo "[]")
FAILED_JSON=$(jq -R -s 'split("\n") | map(select(length>0)) | map((split("|")) as $p | {id: $p[0], name: ($p[1] // ""), reason: ($p[2] // "")})' "$COVERAGE_FAIL_FILE" 2>/dev/null || echo "[]")

AUDITED_COUNT=$(echo "$AUDITED_IDS_JSON" | jq 'length' 2>/dev/null || echo 0)
FAILED_COUNT=$(echo "$FAILED_JSON" | jq 'length' 2>/dev/null || echo 0)
ROW_COUNT=$(( $(wc -l < "$OUTPUT_FILE" 2>/dev/null || echo 1) - 1 ))
[[ "$ROW_COUNT" -lt 0 ]] && ROW_COUNT=0

if [[ "$PIM_READ_OK" == "true" ]]; then PIM_READABLE_JSON=true; else PIM_READABLE_JSON=false; fi

jq -n \
    --arg generatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson discovered "${SUBSCRIPTION_COUNT:-0}" \
    --argjson auditedOk "${AUDITED_COUNT:-0}" \
    --argjson failed "${FAILED_COUNT:-0}" \
    --argjson rowCount "${ROW_COUNT:-0}" \
    --argjson pimEligibleReadable "$PIM_READABLE_JSON" \
    --argjson requestedTenants "${TENANTS_JSON:-[]}" \
    --argjson auditedTenants "${AUDITED_TENANTS_JSON:-[]}" \
    --argjson auditedSubscriptionIds "$AUDITED_IDS_JSON" \
    --argjson failedSubscriptions "$FAILED_JSON" \
    '{
        generatedAt: $generatedAt,
        subscriptionsDiscovered: $discovered,
        subscriptionsAuditedOk: $auditedOk,
        subscriptionsFailed: $failed,
        snapshotRowCount: $rowCount,
        pimEligibleReadable: $pimEligibleReadable,
        requestedTenants: $requestedTenants,
        auditedTenants: $auditedTenants,
        auditedSubscriptionIds: $auditedSubscriptionIds,
        failedSubscriptions: $failedSubscriptions
    }' > "$META_FILE" 2>/dev/null || echo '{}' > "$META_FILE"

echo "Coverage manifest written to: $META_FILE"
if [[ "${FAILED_COUNT:-0}" -gt 0 ]]; then
    echo "  WARNING: ${FAILED_COUNT} of ${SUBSCRIPTION_COUNT} subscription(s) FAILED to audit; this snapshot is INCOMPLETE." >&2
    while IFS='|' read -r fsid fname freason; do
        [[ -z "$fsid" ]] && continue
        echo "    - ${fname:-unknown} (${fsid}): ${freason:-unknown reason}" >&2
    done < "$COVERAGE_FAIL_FILE"
fi

echo "=========================================="
echo "Audit Complete!"
echo "=========================================="
echo ""
echo "Results saved to: $OUTPUT_FILE"
echo ""
echo "Summary:"
# Subtract 1 to exclude header row
RESULT_COUNT=$(( $(wc -l < "$OUTPUT_FILE") - 1 ))
echo "  Subscriptions audited: $SUBSCRIPTION_COUNT"
echo "  Total privileged assignments found: $RESULT_COUNT"
echo ""

echo "To view results:"
echo "  cat $OUTPUT_FILE"
echo "  column -t -s, $OUTPUT_FILE | less -S"
echo ""
echo "=========================================="