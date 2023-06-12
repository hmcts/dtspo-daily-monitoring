#!/usr/bin/env bash

# Used or seding messages to different slack channels for failed deployments

WEBHOOK_URL="${1}"
SLACKCHANNEL="${2}"

MESSAGE=$(cat failed-deployments.txt)
curl -s -X POST --data-urlencode "payload={\"channel\": \"${SLACKCHANNEL}\", \"username\": \"Plato\", \"text\": \"$MESSAGE\", \"icon_emoji\": \":plato:\"}" ${WEBHOOK_URL}