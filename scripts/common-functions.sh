#!/bin/bash

# Check platform
platform=$(uname)

# Check and install missing packages
if [[ $platform == "Darwin" ]]; then
    date_command=$(which gdate)
elif [[ $platform == "Linux" ]]; then
    date_command=$(which date)
fi

# Post a message to a Slack channel
slackNotification() {
    local slack_token=$1
    local channel_name=$2
    local message=$3

    payload="{\"channel\": \"${channel_name}\", \"username\": \"Plato\", \"text\": \"${message}\", \"icon_emoji\": \":plato:\"}"

    RESPONSE=$(curl -s -H "Content-Type: application/json" \
    --data "${payload}" \
    -H "Authorization: Bearer ${slack_token}" \
    -H application/json \
    -X POST https://slack.com/api/chat.postMessage)

    # Extract the timestamp of the posted message
    TS=$(echo $RESPONSE | jq -r '.ts')
    echo "Message posted with timestamp: $TS"
}

# Post a threaded reply to a Slack message
slackThreadResponse() {
    local slack_token=$1
    local channel_name=$2
    local message=$3
    local parent_ts=$4

    payload="{\"channel\": \"${channel_name}\", \"username\": \"Plato\", \"text\": \"${message}\", \"thread_ts\": \"${parent_ts}\", \"icon_emoji\": \":plato:\"}"

    curl -s -H "Content-Type: application/json" \
    --data "${payload}" \
    -H "Authorization: Bearer ${slack_token}" \
    -H application/json \
    -X POST https://slack.com/api/chat.postMessage

}
