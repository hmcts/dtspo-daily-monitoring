#!/usr/bin/env bash

set -euo pipefail

slackBotToken=
slackChannelName=
forceRun=false

# Update this list when GA break-glass accounts are added, removed, or changed.
ACCOUNTS='felix.eyetanga@HMCTS.NET,Thomas.ThorntonGA@HMCTS.NET'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT_DIR="$SCRIPT_DIR"
REPORT_MD="$REPORT_DIR/breakglass-signin-review.md"

mkdir -p "$REPORT_DIR"

usage() {
    cat << EOF
Usage: $0 [--slackBotToken TOKEN] [--slackChannelName CHANNEL] [--force]
EOF
    exit 1
}

args=$(getopt -a -o t:c:h --long slackBotToken:,slackChannelName:,force,help -- "$@") || usage
eval set -- "$args"

while :; do
    case "$1" in
        -t | --slackBotToken)
            slackBotToken=$2
            shift 2
            ;;
        -c | --slackChannelName)
            slackChannelName=$2
            shift 2
            ;;
        --force)
            forceRun=true
            shift
            ;;
        -h | --help)
            usage
            ;;
        --)
            shift
            break
            ;;
        *)
            usage
            ;;
    esac
done

# The scheduled pipeline runs on the 18th of every month.
# --force can be used for manual testing on another day.
if [[ "$forceRun" != true && "$(date -u +'%d')" != '18' ]]; then
    echo "Skipping break-glass sign-in review; scheduled for the 18th of each month."
    exit 0
fi

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common-functions.sh"

echo "Getting Microsoft Graph token..."

TOKEN=$(az account get-access-token \
    --resource-type ms-graph \
    --query accessToken \
    -o tsv)

if [[ -z "$TOKEN" ]]; then
    echo "No token returned for Microsoft Graph. Check service connection permissions."
    exit 1
fi

IFS=',' read -ra accounts <<< "$ACCOUNTS"

generated_at="$(date -u +'%Y-%m-%d %H:%M:%S') UTC"

printf "# Break-glass sign-in review\n\n" > "$REPORT_MD"
printf "**Generated:** %s\n\n" "$generated_at" >> "$REPORT_MD"
printf "**Review frequency:** Monthly - 18th of each month\n\n" >> "$REPORT_MD"
printf "**Requirement:** Each break-glass GA account must have a successful sign-in within the last 12 months.\n\n" >> "$REPORT_MD"
printf "| Account | Last Successful Sign-in (UTC) | Days Since Sign-in | Status |\n" >> "$REPORT_MD"
printf "| --- | --- | ---: | --- |\n" >> "$REPORT_MD"

parse_epoch() {
    local timestamp=$1

    date -u -d "$timestamp" +%s 2>/dev/null || \
        date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$timestamp" +%s
}

has_stale_account=false
total_accounts=0
stale_accounts=0
slack_details=""

for account in "${accounts[@]}"; do
    account=$(echo "$account" | xargs)

    [[ -n "$account" ]] || continue

    total_accounts=$((total_accounts + 1))

    echo "Checking $account"

    user_id=$(az rest \
        --method GET \
        --url "https://graph.microsoft.com/v1.0/users/$account" \
        --headers "Authorization=Bearer $TOKEN" \
        --query "id" \
        -o tsv || true)

    if [[ -z "$user_id" || "$user_id" == "null" ]]; then
        echo "Chase Required: $account not found or not readable"

        printf "| %s | - | - | 🔴 Chase Required |\n" \
            "$account" >> "$REPORT_MD"

        has_stale_account=true
        stale_accounts=$((stale_accounts + 1))

        slack_details+="\n🔴 $account — account not found or not readable"
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

        printf "| %s | - | - | 🔴 Chase Required |\n" \
            "$account" >> "$REPORT_MD"

        has_stale_account=true
        stale_accounts=$((stale_accounts + 1))

        slack_details+="\n🔴 $account — no successful sign-in recorded"
        continue
    fi

    now_epoch=$(date -u +%s)
    last_epoch=$(parse_epoch "$last_success")
    days_since=$(( (now_epoch - last_epoch) / 86400 ))

    echo "$account last successful sign-in: $days_since days ago"

    if [[ "$days_since" -gt 365 ]]; then

        echo "Chase Required: $account has not signed in in the last 12 months"

        printf "| %s | %s | %s | 🔴 Chase Required |\n" \
            "$account" \
            "$last_success" \
            "$days_since" >> "$REPORT_MD"

        has_stale_account=true
        stale_accounts=$((stale_accounts + 1))

        slack_details+="\n🔴 $account — last successful sign-in was $days_since days ago"

    else

        printf "| %s | %s | %s | 🟢 OK |\n" \
            "$account" \
            "$last_success" \
            "$days_since" >> "$REPORT_MD"

        slack_details+="\n🟢 $account — last successful sign-in: $last_success ($days_since days ago)"
    fi
done

# Overall result
if [[ "$has_stale_account" == true ]]; then
    overall_status="🔴 Follow-up Required"
    overall_message="One or more break-glass accounts require follow-up."
else
    overall_status="🟢 All Accounts Compliant"
    overall_message="All registered break-glass accounts have signed in within the last 12 months."
fi

# Add summary to Markdown report
printf "\n## Summary\n\n" >> "$REPORT_MD"
printf "**Status:** %s\n\n" "$overall_status" >> "$REPORT_MD"
printf "**Accounts reviewed:** %s\n\n" "$total_accounts" >> "$REPORT_MD"
printf "**Accounts requiring follow-up:** %s\n\n" "$stale_accounts" >> "$REPORT_MD"

echo "Report written to $REPORT_MD"

# Send one monthly Slack notification
if [[ -n "$slackBotToken" && -n "$slackChannelName" ]]; then

    slack_message="$overall_status Break-glass sign-in review

Monthly review completed: $(date -u +'%d %B %Y')

Accounts reviewed: $total_accounts
Accounts requiring follow-up: $stale_accounts

$overall_message

Account details:
$slack_details

Requirement: Each break-glass GA account must have a successful sign-in within the last 12 months."

    slackNotification \
        "$slackBotToken" \
        "$slackChannelName" \
        "🔐 Break-glass sign-in review" \
        "$slack_message"

else
    echo "Slack notification skipped: token or channel was not supplied." >&2
fi

# Make the pipeline show a warning/failure when follow-up is required.
# The AzureCLI task has continueOnError: true, so the pipeline will continue
# and the report will still be published.
if [[ "$has_stale_account" == true ]]; then

    echo "##vso[task.logissue type=warning]One or more break-glass accounts require sign-in follow-up."

    exit 1
fi

exit 0