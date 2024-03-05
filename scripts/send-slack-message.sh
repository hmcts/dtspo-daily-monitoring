#!/usr/bin/env bash

SLACK_BOT_TOKEN=$1
CHANNEL_NAME=$2

MESSAGE=$(cat slack-message.txt)

payload="{\"channel\": \"${CHANNEL_NAME}\", \"username\": \"Plato\", \"text\": \"${MESSAGE}\", \"icon_emoji\": \":plato:\"}"

curl -s -H "Content-type: application/json" \
--data "${payload}" \
-H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
-H application/json \
-X POST https://slack.com/api/chat.postMessage