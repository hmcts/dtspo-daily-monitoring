#!/usr/bin/env bash

# SLACK_BOT_TOKEN=$1
# PULL_REQUEST_NUMBER=$2
# GITHUB_TOKEN=$3

WEBHOOK_URL=$1
CHANNEL_NAME=$2

# GITHUB_USER=$(curl -s -L -H "Accept: application/vnd.github+json" -H "Authorization: Bearer ${GITHUB_TOKEN}" -H "X-GitHub-Api-Version: 2022-11-28" "https://api.github.com/repos/hmcts/dtspo-daily-monitoring/pulls/$PULL_REQUEST_NUMBER"  | jq -r '.user.login')

# CHANNEL_NAME=$(curl -s https://raw.githubusercontent.com/hmcts/github-slack-user-mappings/master/slack.json | jq --arg GITHUB_USER "$GITHUB_USER" -r '.[][] | (select(.github | contains($GITHUB_USER)))' | jq -r '.slack')

MESSAGE=$(cat slack-message.txt)
echo $MESSAGE
# echo $CHANNEL_NAME
# payload="{\"channel\": \"${CHANNEL_NAME}\", \"username\": \"Plato\", \"text\": \"${MESSAGE}\", \"icon_emoji\": \":plato:\"}"

# echo $payload


# curl -s -H "Content-type: application/json" \
# --data "${payload}" \
# -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
# -H application/json \
# -X POST https://slack.com/api/chat.postMessage

curl -s -X POST --data-urlencode "payload={\"channel\": \"${CHANNEL_NAME}\", \"username\": \"Plato\", \"text\": \"${MESSAGE}\", \"icon_emoji\": \":plato:\"}" ${WEBHOOK_URL}