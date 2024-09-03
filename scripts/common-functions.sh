#!/bin/bash

# Check platform
platform=$(uname)

# Check and install missing packages
if [[ $platform == "Darwin" ]]; then
    date_command=$(which gdate)
elif [[ $platform == "Linux" ]]; then
    date_command=$(which date)
fi

# Check if the values of githubToken and pullRequestNumber are supplied and if so return the name of the Github user as Slack Channel
isPR(){
    local githubToken=$1
    local pullRequestNumber=$2

    if [ -n "$githubToken" ] && [ -n "$pullRequestNumber" ]; then
        GITHUB_USER=$(curl -s -L -H "Accept: application/vnd.github+json" -H "Authorization: Bearer ${githubToken}" -H "X-GitHub-Api-Version: 2022-11-28" "https://api.github.com/repos/hmcts/dtspo-daily-monitoring/pulls/$pullRequestNumber"  | jq -r '.user.login')
        PR_CHANNEL_NAME=$(curl -s https://raw.githubusercontent.com/hmcts/github-slack-user-mappings/master/slack.json | jq --arg GITHUB_USER "$GITHUB_USER" -r '.[][] | (select(.github | contains($GITHUB_USER)))' | jq -r '.slack')
        return 0
    else
        echo "This is not a Pull Request, check completed."
        return 1
    fi
}

# Post a message to a Slack channel
post_message() {
    local slack_token=$1
    local channel_name=$2
    local message=$3

    RESPONSE=$(curl -s -X POST -H "Authorization: Bearer $slack_token" \
    -H "Content-Type: application/json" \
    -d "{
        "channel": "${channel_name}",
        "username": "Plato",
        "text": "${message}",
        "icon_emoji": ":plato:"
    }" https://slack.com/api/chat.postMessage)

    # Extract the timestamp of the posted message
    TS=$(echo $RESPONSE | jq -r '.ts')
    echo "Message posted with timestamp: $TS"
}

# Post a threaded reply to a Slack message
post_threaded_reply() {
    local slack_token=$1
    local channel_name=$2
    local message=$3
    local parent_ts=$4

    curl -s -X POST -H "Authorization: Bearer $slack_token" \
    -H "Content-Type: application/json" \
    -d "{
        "channel": "${channel_name}",
        "text": "${message}",
        "thread_ts": "${parent_ts}",
    }" https://slack.com/api/chat.postMessage
}
