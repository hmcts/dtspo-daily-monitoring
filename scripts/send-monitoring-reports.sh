#!/usr/bin/env bash
set -euo pipefail

source scripts/common-functions.sh

reportDirectory=${1:?Usage: $0 <report-directory> <slack-token> <recipient>}
slackBotToken=${2:?Slack token is required}
slackRecipient=${3:?Slack recipient is required}

if [[ ! -f "$reportDirectory/.ready" ]]; then
    echo "Monitoring reports could not be collected from $reportDirectory." >&2
    slackNotification "$slackBotToken" "$slackRecipient" \
        ":red_circle: Monitoring reports unavailable" \
        "Reports could not be collected from $(basename "$reportDirectory"). Review the pipeline logs."
    exit 1
fi

shopt -s nullglob
reportFiles=("$reportDirectory"/report-*)
if [[ ${#reportFiles[@]} -eq 0 ]]; then
    exit 0
fi
for reportFile in "${reportFiles[@]}"; do
    if ! jq -e -s 'length == 1 and all(.[];
        type == "object" and (.header | type == "string") and
        (.message | type == "string") and (.replies | type == "array") and
        all(.replies[]; type == "string"))' "$reportFile" >/dev/null; then
        printf 'Invalid monitoring report: %s. The file is incomplete or has an invalid report structure.\n' "$reportFile" >&2
        exit 1
    fi
done
sortedReports=$(jq -sc '
    if all(.[]; type == "object" and (.header | type == "string") and
        (.message | type == "string") and (.replies | type == "array") and
        all(.replies[]; type == "string")) then
        sort_by([(.header | gsub(":[A-Za-z0-9_+-]+:"; "") |
            gsub("[*_]"; "") | gsub("^\\s+|\\s+$"; "") | ascii_downcase), .header])[]
    else error("Invalid monitoring report") end
' "${reportFiles[@]}")
while IFS= read -r report; do
    header=$(jq -r '.header' <<< "$report")
    message=$(jq -r '.message' <<< "$report")
    slackNotification "$slackBotToken" "$slackRecipient" "$header" "$message"
    while IFS= read -r reply; do
        message=$(jq -r '.' <<< "$reply")
        slackThreadResponse "$slackBotToken" "$slackRecipient" "$message" "$TS"
    done < <(jq -c '.replies[]' <<< "$report")
done <<< "$sortedReports"