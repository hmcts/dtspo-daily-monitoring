# Azure Privileged RBAC Role Audit Script
# Purpose: Identify all principals (users, service principals, managed identities, groups)
#          with priv admin roles we are concerned about
# Scope: All non-sandbox subscriptions
# Excludes: Sandbox environments

set -e

# Remove all ASCII control characters that can break JSON parsing in jq.
sanitize_json() {
    python3 -c "import sys,re; sys.stdout.write(re.sub(r'[\\x00-\\x1f]', '', sys.stdin.read()))"
}

echo "=========================================="
echo "Azure RBAC Privileged Access Audit - All Subscriptions"
echo "=========================================="
echo ""

# Output file (date-stamped snapshot; overridable for CI / pipeline artifacts)
OUTPUT_FILE=""
OUTPUT_DIR=""

usage() {
    cat >&2 <<EOF
Usage: $0 [--outputFile <path>] [--outputDir <dir>]
  --outputFile <path>  Full path to write the CSV snapshot
  --outputDir  <dir>   Directory to write rbac-snapshot-<YYYY-MM-DD>.csv into
                       (default: current directory)
  -h, --help           Show this help
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--outputFile) OUTPUT_FILE="$2"; shift 2 ;;
        -d|--outputDir)  OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help)       usage ;;
        *) echo "Unknown option: $1" >&2; usage ;;
    esac
done

if [[ -z "$OUTPUT_FILE" ]]; then
    OUTPUT_DIR="${OUTPUT_DIR:-.}"
    mkdir -p "$OUTPUT_DIR"
    OUTPUT_FILE="${OUTPUT_DIR}/rbac-snapshot-$(date -u +%Y-%m-%d).csv"
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

# Ensure logged in (non-interactive; in CI run inside an AzureCLI@2 task)
echo "Verifying Azure login..."
if ! az account show > /dev/null 2>&1; then
    echo "Error: not authenticated to Azure. Run 'az login' locally, or execute this script inside an AzureCLI@2 task in CI." >&2
    exit 1
fi

echo ""
echo "Fetching all subscriptions..."

# Get all subscriptions (excluding sandbox/sbox)
SUBSCRIPTIONS=$(az account list --query "[?!contains(name, 'sandbox') && !contains(name, 'sbox') && !contains(name, 'Sandbox') && !contains(name, 'SBOX')].{id:id, name:name}" -o json | sanitize_json)

if ! echo "$SUBSCRIPTIONS" | jq -e . >/dev/null 2>&1; then
    echo "Error: unable to parse subscription list as JSON after sanitization"
    exit 1
fi

SUBSCRIPTION_COUNT=$(echo "$SUBSCRIPTIONS" | jq '. | length')
echo "Found $SUBSCRIPTION_COUNT non-sandbox subscriptions to audit"
echo ""

echo "Starting audit..."
echo ""

# Write CSV header
echo "PrincipalId,RoleDefinitionId,DisplayName,Identifier,IdentityType,RoleName,DurationType,ExpiresOn,Scope,ScopeType,SubscriptionName,SubscriptionId,AssignmentId" > "$OUTPUT_FILE"

# Counter for progress
CURRENT=0
TOTAL_FINDINGS=0

# Process each subscription
echo "$SUBSCRIPTIONS" | jq -c '.[]' | while read -r sub; do
    CURRENT=$((CURRENT + 1))
    SUB_ID=$(echo "$sub" | jq -r '.id')
    SUB_NAME=$(echo "$sub" | jq -r '.name')
    
    echo "[$CURRENT/$SUBSCRIPTION_COUNT] Processing: $SUB_NAME"
    
    # Set active subscription
    az account set --subscription "$SUB_ID"
    
    # Get all role assignments for this subscription at all scopes (all principal types)
    echo "  Fetching role assignments..."
    ASSIGNMENTS=$(az role assignment list --all -o json | sanitize_json)

    if ! echo "$ASSIGNMENTS" | jq -e . >/dev/null 2>&1; then
        echo "  Warning: invalid role assignment JSON in $SUB_NAME after sanitization, skipping subscription"
        echo ""
        continue
    fi
    
    TOTAL_ASSIGNMENTS=$(echo "$ASSIGNMENTS" | jq '. | length')
    echo "  Found $TOTAL_ASSIGNMENTS assignments, filtering for privileged roles..."

    # Fetch schedule instances to determine permanent vs temporary assignments
    echo "  Fetching assignment schedule data..."
    #double failure failsafe
    SCHEDULE_INSTANCES=$(az rest --method GET \
        --url "https://management.azure.com/subscriptions/$SUB_ID/providers/Microsoft.Authorization/roleAssignmentScheduleInstances?api-version=2020-10-01-preview" \
        -o json 2>/dev/null \
        | sanitize_json \
        | jq '.value // []' || echo "[]")
    
    # Process each assignment
    echo "$ASSIGNMENTS" | jq -c '.[]' | while read -r assignment; do
        ROLE_NAME=$(echo "$assignment" | jq -r '.roleDefinitionName')
        
        # Check if this role is in our privileged list
        for PRIV_ROLE in "${PRIVILEGED_ROLES[@]}"; do
            if [[ "$ROLE_NAME" == "$PRIV_ROLE" ]]; then
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

                # Escape any commas or double-quotes in fields for CSV safety
                csv_field() { echo "$1" | sed 's/"/""/g' | awk '{print "\"" $0 "\"";}'; }

                # Write CSV row
                printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
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
                    >> "$OUTPUT_FILE"
                
                break
            fi
        done
    done
    
    echo ""
done

# Sort data rows deterministically (header preserved) so day-to-day diffs are stable
if [[ -f "$OUTPUT_FILE" ]]; then
    SORTED_TMP="$(mktemp)"
    { head -n 1 "$OUTPUT_FILE"; tail -n +2 "$OUTPUT_FILE" | LC_ALL=C sort; } > "$SORTED_TMP"
    mv "$SORTED_TMP" "$OUTPUT_FILE"
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
echo "Breakdown by identity type:"
tail -n +2 "$OUTPUT_FILE" | awk -F',' '{gsub(/"/,"",$5); counts[$5]++} END {for (t in counts) print "  " counts[t] " " t}'
echo ""

echo "To view results:"
echo "  cat $OUTPUT_FILE"
echo "  column -t -s, $OUTPUT_FILE | less -S"
echo ""
echo "=========================================="