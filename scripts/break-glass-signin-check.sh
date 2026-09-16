#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common-functions.sh"

slackBotToken=
slackChannelName=
# Update this list when GA break-glass accounts are added, removed, or changed.
ACCOUNTS='felix.eyetanga@HMCTS.NET,Thomas.ThorntonGA@HMCTS.NET'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT_DIR="$SCRIPT_DIR"
REPORT_FILE="$REPORT_DIR/breakglass-signin-review.csv"
REPORT_MD="$REPORT_DIR/breakglass-signin-review.md"

mkdir -p "$REPORT_DIR"

usage() {
    cat << EOF
Usage: $0 [--slackBotToken TOKEN] [--slackChannelName CHANNEL]
EOF
    exit 1
}

args=$(getopt -a -o t:c:h --long slackBotToken:,slackChannelName:,help -- "$@") || usage
eval set -- "$args"
while :; do
    case "$1" in
        -t | --slackBotToken)    slackBotToken=$2; shift 2 ;;
        -c | --slackChannelName) slackChannelName=$2; shift 2 ;;
        -h | --help)             usage ;;
        --)                      shift; break ;;
        *)                       usage ;;
    esac
done

echo "Getting Microsoft Graph token..."
TOKEN=$(az account get-access-token --resource-type ms-graph --query accessToken -o tsv)

if [[ -z "$TOKEN" ]]; then
    echo "No token returned for Microsoft Graph. Check service connection permissions."
    exit 1
fi

IFS=',' read -ra accounts <<< "$ACCOUNTS"

printf "UserPrincipalName,LastSuccessfulSignInUTC,DaysSinceSignIn,Status\n" > "$REPORT_FILE"
printf "# Break-glass sign-in review\n\n" > "$REPORT_MD"
printf "Generated: %s UTC\n\n" "$(date -u +'%Y-%m-%d %H:%M:%S')" >> "$REPORT_MD"
printf "Threshold: no successful sign-in in the last 12 months = Chase Required\n\n" >> "$REPORT_MD"
printf "| UserPrincipalName | LastSuccessfulSignInUTC | DaysSinceSignIn | Status |\n" >> "$REPORT_MD"
printf "| --- | --- | ---: | --- |\n" >> "$REPORT_MD"

parse_epoch() {
    local timestamp=$1

    date -u -d "$timestamp" +%s 2>/dev/null || \
        date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$timestamp" +%s
}

has_stale_account=false
chase_details=

for account in "${accounts[@]}"; do
    account=$(echo "$account" | xargs)
    [[ -n "$account" ]] || continue

    echo "Checking $account"

    user_id=$(az rest \
        --method GET \
        --url "https://graph.microsoft.com/v1.0/users/$account" \
        --headers "Authorization=Bearer $TOKEN" \
        --query "id" \
        -o tsv || true)

    if [[ -z "$user_id" || "$user_id" == "null" ]]; then
        echo "Chase Required: $account not found or not readable"
        printf "%s,,,%s\n" "$account" "Chase Required" >> "$REPORT_FILE"
        printf "| %s | - | - | Chase Required |\n" "$account" >> "$REPORT_MD"
        has_stale_account=true
        chase_details+="\n:red_circle: $account not found or not readable"
        continue
    fi

    last_success=$(az rest \
        --method GET \
        --url "https://graph.microsoft.com/v1.0/auditLogs/signIns?\$filter=userId eq '$user_id' and status/errorCode eq 0&\$top=1&\$orderby=createdDateTime desc" \
        --headers "Authorization=Bearer $TOKEN" \
        --query "value[0].createdDateTime" \
        -o tsv || true)

    if [[ -z "$last_success" || "$last_success" == "null" ]]; then
        echo "Chase Required: no successful sign-in found for $account"
        printf "%s,,,%s\n" "$account" "Chase Required" >> "$REPORT_FILE"
        printf "| %s | - | - | Chase Required |\n" "$account" >> "$REPORT_MD"
        has_stale_account=true
        chase_details+="\n:red_circle: $account has no successful sign-in recorded"
        continue
    fi

    now_epoch=$(date -u +%s)
    last_epoch=$(parse_epoch "$last_success")
    days_since=$(( (now_epoch - last_epoch) / 86400 ))

    echo "$account last successful sign-in: $days_since days ago"

    if [[ "$days_since" -gt 365 ]]; then
        echo "Chase Required: $account has not signed in in the last 12 months"
        printf "%s,%s,%s,%s\n" "$account" "$last_success" "$days_since" "Chase Required" >> "$REPORT_FILE"
        printf "| %s | %s | %s | Chase Required |\n" "$account" "$last_success" "$days_since" >> "$REPORT_MD"
        has_stale_account=true
        chase_details+="\n:red_circle: $account last signed in $days_since days ago"
        continue
    fi

    printf "%s,%s,%s,%s\n" "$account" "$last_success" "$days_since" "OK" >> "$REPORT_FILE"
    printf "| %s | %s | %s | OK |\n" "$account" "$last_success" "$days_since" >> "$REPORT_MD"
done

echo "All GA accounts have had a successful sign-in in the last 12 months." > /tmp/ga_status.txt
if [[ "$has_stale_account" == true ]]; then
    echo "One or more GA accounts require chase follow-up." >> /tmp/ga_status.txt
fi

echo "Report written to $REPORT_FILE and $REPORT_MD"

if [[ "$has_stale_account" == true ]]; then
    if [[ -n "$slackBotToken" && -n "$slackChannelName" ]]; then
        slackNotification "$slackBotToken" "$slackChannelName" \
            ":red_circle: Break-glass sign-in review" \
            "For Platform Access posture, break-glass GA accounts must sign in to the CNP tenant at least once every 12 months.\n\nAction required: please update the script if new break-glass GA accounts have been added, or chase the affected users to sign in to the CNP tenant."
        slackThreadResponse "$slackBotToken" "$slackChannelName" "Affected accounts and latest sign-in details:$chase_details" "$TS"
    else
        echo "Slack notification skipped: token or channel was not supplied." >&2
    fi
    exit 1
fi