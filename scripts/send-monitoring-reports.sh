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
for reportFile in "$reportDirectory"/report-*; do
    jq -e 'type == "object" and (.header | type == "string") and
        (.message | type == "string") and (.replies | type == "array") and
        all(.replies[]; type == "string")' "$reportFile" >/dev/null
    header=$(jq -r '.header' "$reportFile")
    message=$(jq -r '.message' "$reportFile")
    slackNotification "$slackBotToken" "$slackRecipient" "$header" "$message"
    while IFS= read -r reply; do
        message=$(jq -r '.' <<< "$reply")
        slackThreadResponse "$slackBotToken" "$slackRecipient" "$message" "$TS"
    done < <(jq -c '.replies[]' "$reportFile")
done