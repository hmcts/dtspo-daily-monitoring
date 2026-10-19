#!/usr/bin/env bash

# This script will download the latest output from the orphaned resource deletion repository that contains any resources that could not be deleted.
# This will then be sent to Slack in the Daily Checks channel for easier monitoring by all teams.

### Setup script environment
set -euo pipefail

# Source central functions script
source scripts/common-functions.sh

slackBotToken=
slackChannelName=
URL="https://raw.githubusercontent.com/hmcts/dtspo-orphan-resources-cleanup/refs/heads/master/status/deletionStatus.json"

usage(){
>&2 cat << EOF
------------------------------------------------
Script to verify historical orphan-resource failures (read-only)
------------------------------------------------
Usage: $0
    [ -t | --slackBotToken ]
    [ -c | --slackChannelName ]
    [ -h | --help ]
EOF
exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -h | --help) usage ;;
        -t | --slackBotToken)
            [[ $# -ge 2 ]] || usage
            slackBotToken=$2; shift 2 ;;
        -c | --slackChannelName)
            [[ $# -ge 2 ]] || usage
            slackChannelName=$2; shift 2 ;;
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

workDir=$(mktemp -d)
trap 'rm -f "$workDir/status.json" "$workDir/filtered.json" "$workDir/report.json"; rmdir "$workDir"' EXIT

reportFailure() {
    echo "$1" >&2
    slackNotification "$slackBotToken" "$slackChannelName" \
        ":red_circle: Historical cleanup verification errors" "$1 No resources were deleted."
}

if ! curl --fail --silent --show-error --location "$URL" > "$workDir/status.json"; then
    reportFailure "Could not download the historical cleanup failure list; current resource existence is unknown."
    exit 1
fi

# Filter out auto-created AKS NSGs in node resource groups
# These are automatically created by Azure and cannot be deleted, so we ignore them
if ! jq 'if type != "array" then error("Expected a failure array") else [.[] | select(
    (.message | test("/subscriptions/.*/resourceGroups/.*-aks-node-rg/providers/Microsoft.Network/networkSecurityGroups/aks-appgateway-.*-nsg"; "i") | not) and
    (.message | test("/subscriptions/.*/resourceGroups/.*-aks-node-rg/providers/Microsoft.Network/networkSecurityGroups/aks-virtualkubelet-.*-nsg"; "i") | not)
)] end' "$workDir/status.json" > "$workDir/filtered.json"; then
    reportFailure "The historical cleanup failure list is invalid; current resource existence is unknown."
    exit 1
fi

verificationExit=0
bash scripts/reconcile-orphan-resources.sh "$workDir/filtered.json" > "$workDir/report.json" || verificationExit=$?

if ! jq -e 'type == "object" and (.resources | type == "array") and
    (.checkedAt | type == "string") and (.summary | type == "object")' \
    "$workDir/report.json" >/dev/null; then
    reportFailure "Read-only verification could not produce a valid report; current resource existence is unknown."
    exit 1
fi

existingCount=$(jq '.summary.exists' "$workDir/report.json")
unverifiedCount=$(jq '.summary.unverified' "$workDir/report.json")
notFoundCount=$(jq '.summary.notFound' "$workDir/report.json")
checkedAt=$(jq -r '.checkedAt' "$workDir/report.json")
summary="Verified at $checkedAt (UTC): $existingCount still exist; $notFoundCount confirmed not found; $unverifiedCount could not be verified. No resources were deleted."

if [[ "$existingCount" -gt 0 ]]; then
    slackNotification "$slackBotToken" "$slackChannelName" \
        ":red_circle: Historical cleanup failures — still exists" \
        "$summary These are historical failures, not new deletion attempts or proof that the resources are orphaned."
    while IFS= read -r resourceId; do
        slackThreadResponse "$slackBotToken" "$slackChannelName" "$resourceId" "$TS"
    done < <(jq -r '.resources[] | select(.status == "exists") | .id' "$workDir/report.json")
fi

if [[ "$unverifiedCount" -gt 0 ]]; then
    slackNotification "$slackBotToken" "$slackChannelName" \
        ":red_circle: Historical cleanup verification errors" \
        "$summary Unverified resources must not be treated as deleted."
    while IFS= read -r record; do
        message=$(jq -r '.id + "\n" + .detail' <<< "$record")
        slackThreadResponse "$slackBotToken" "$slackChannelName" "$message" "$TS"
    done < <(jq -c '.resources[] | select(.status == "unverified")' "$workDir/report.json")
fi

echo "$summary"
if [[ "$verificationExit" -ne 0 || "$unverifiedCount" -gt 0 ]]; then
    if [[ "$unverifiedCount" -eq 0 ]]; then
        reportFailure "Read-only verification exited unexpectedly; review the pipeline logs."
    fi
    exit 1
fi
