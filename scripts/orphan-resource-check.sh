#!/usr/bin/env bash

# This script will download the latest output from the orphaned resource deletion repository that contains any resources that could not be deleted.
# This will then be sent to Slack in the Daily Checks channel for easier monitoring by all teams.

### Setup script environment
set -euo pipefail

# Source central functions script
source scripts/common-functions.sh

slackBotToken=
slackChannelName=
URL="https://raw.githubusercontent.com/hmcts/dtspo-orphan-resources-cleanup/refs/heads/master/status/deletionStatus.json"

usage(){
>&2 cat << EOF
------------------------------------------------
Script to check GitHub page expiry
------------------------------------------------
Usage: $0
    [ -t | --slackBotToken ]
    [ -c | --slackChannelName ]
    [ -h | --help ]
EOF
exit 1
}

args=$(getopt -a -o t:c:h: --long slackBotToken:,slackChannelName:,help -- "$@")
if [[ $? -gt 0 ]]; then
    usage
fi

eval set -- ${args}
while :
do
    case $1 in
        -h | --help)              usage                    ; shift   ;;
        -t | --slackBotToken)     slackBotToken=$2         ; shift 2 ;;
        -c | --slackChannelName)  slackChannelName=$2      ; shift 2 ;;
        # -- means the end of the arguments; drop this, and break out of the while loop
        --) shift; break ;;
        *) >&2 echo Unsupported option: $1
            usage ;;
    esac
done

if [[ -z "$slackBotToken" || -z "$slackChannelName" ]]; then
    {
        echo "------------------------"
        echo 'Please supply all of: '
        echo '- Slack token'
        echo '- Slack channel name'
        echo "------------------------"
    } >&2
    exit 1
fi

# Download data from URL
jsonData=$(curl -s $URL)

# Check if any records exist
deletedResourceCount=$(echo "$jsonData" | jq 'length')

# Set STATUS based on the object count
if [ "$deletedResourceCount" -gt 0 ]; then
    STATUS=":red_circle:"

    failedDeletes=$(jq --arg status "$STATUS" -r '.[].message | gsub("A resource failed to delete!\\\\nTo see why, you can run: az resource delete --ids "; "") | gsub("--verbose\\\\n"; "") | $status + " " + .' <<< "$jsonData")


    # Post initial header message
    slackNotification $slackBotToken $slackChannelName "$STATUS Orphaned Resource Status" "$deletedResourceCount resources failed to delete, <https://github.com/hmcts/dtspo-orphan-resources-cleanup/actions|*_Orphaned Resource Pipeline_*>"

    # Send to slack thread
    slackThreadResponse $slackBotToken $slackChannelName "The following resources could not be deleted, you can find more information by running: \n 'az resource delete --ids (RESOURCE ID) --verbose'" $TS
    slackThreadResponse $slackBotToken $slackChannelName "$failedDeletes" $TS
fi
