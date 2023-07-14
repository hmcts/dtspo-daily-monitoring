#!/usr/bin/env bash

WEBHOOK_URL=$1
CHANNEL_NAME=$2
BUILD_QUEUED_BY=$3

echo $BUILD_QUEUED_BY

MESSAGE=$(cat slack-message.txt)
curl -s -X POST --data-urlencode "payload={\"channel\": \"${CHANNEL_NAME}\", \"username\": \"Plato\", \"text\": \"${MESSAGE}\", \"icon_emoji\": \":plato:\"}" ${WEBHOOK_URL}