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
    local header=$3
    local message=$4

    # Use jq with variables
    headerPayload=$(jq --arg header "$header" \
                    --arg message "$message" \
                    '.[0].text.text |= $header | .[1].text.text |= $message' scripts/header-block-template.json)

    # Construct the payload with blocks directly
    payload=$(jq -n --arg channel "${channel_name}" \
            --arg username "Plato" \
            --arg icon_emoji ":plato:" \
            --argjson blocks "$headerPayload" \
            '{channel: $channel, username: $username, blocks: $blocks, icon_emoji: $icon_emoji, unfurl_links: false}')

    RESPONSE=$(curl -s -H "Content-Type: application/json" \
    --data "${payload}" \
    -H "Authorization: Bearer ${slack_token}" \
    -H application/json \
    -X POST https://slack.com/api/chat.postMessage)

    # Extract the timestamp of the posted message
    TS=$(echo $RESPONSE | jq -r '.ts')
}

# Post a threaded reply to a Slack message
slackThreadResponse() {
    local slack_token=$1
    local channel_name=$2
    local message=$3
    local parent_ts=$4
    local msg_file payload_file rc=0

    # Build the payload with jq for correct JSON escaping, reading the (possibly
    # large) message from a file via --rawfile and writing the payload to a file.
    # Neither the message nor the payload is ever passed as a command-line
    # argument, so a big report cannot overflow the per-argument length limit and
    # fail with "Argument list too long".
    msg_file="$(mktemp)"
    payload_file="$(mktemp)"
    printf '%s' "$message" > "$msg_file"

    jq -n --arg channel "${channel_name}" \
          --arg username "Plato" \
          --rawfile text "$msg_file" \
          --arg thread_ts "${parent_ts}" \
          --arg icon_emoji ":plato:" \
          '{channel: $channel, username: $username, text: $text, thread_ts: $thread_ts, icon_emoji: $icon_emoji}' \
          > "$payload_file"

    curl -s -H "Content-Type: application/json" \
    --data @"$payload_file" \
    -H "Authorization: Bearer ${slack_token}" \
    -X POST https://slack.com/api/chat.postMessage || rc=$?

    rm -f "$msg_file" "$payload_file"
    return $rc
}

# Update existing message in a Slack channel
slackMessageUpdate() {
    local slack_token=$1
    local channel_name=$2
    local header=$3
    local message=$4
    local timeStamp=$5

    # Use jq with variables
    headerPayload=$(jq --arg header "$header" \
                    --arg message "$message" \
                    '.[0].text.text |= $header | .[1].text.text |= $message' scripts/header-block-template.json)

    # Construct the payload with blocks directly
    payload=$(jq -n --arg channel "${channel_name}" \
            --arg ts "${timeStamp}" \
            --argjson blocks "$headerPayload" \
            '{channel: $channel, blocks: $blocks, ts: $ts, unfurl_links: false}')

    # Send update to slack message
    curl -s -H "Content-Type: application/json" \
    --data "${payload}" \
    -H "Authorization: Bearer ${slack_token}" \
    -H application/json \
    -X POST https://slack.com/api/chat.update
}
