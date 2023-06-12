#!/usr/bin/env bash

# Used or seding messages to different slack channels for failed deployments

SUBSCRIPTION="${1}"
RESOURCEGROUP="${2}"
CLUSTER_NAME="${3}"
SLACKCHANNEL="${4}"
WEBHOOK_URL="${5}"

MESSAGE=$(cat failed-deployments.txt)
curl -s -X POST --data-urlencode "payload={\"channel\": \"${SLACKCHANNEL}\", \"username\": \"Plato\", \"text\": \"$MESSAGE\", \"icon_emoji\": \":plato:\"}" ${WEBHOOK_URL}