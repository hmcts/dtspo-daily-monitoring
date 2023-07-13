#!/usr/bin/env bash

WEBHOOK_URL=$1
CHANNEL_NAME=$2

cat slack-message.txt

MESSAGE=$(cat slack-message.txt)
curl -s -X POST --data-urlencode "payload={\"channel\": \"${CHANNEL_NAME}\", \"username\": \"Plato\", \"text\": \"$MESSAGE\", \"icon_emoji\": \":plato:\"}" ${WEBHOOK_URL}