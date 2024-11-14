#!/usr/bin/env bash

# This script will curl the output of the pages found in the URLS array and use JQ to parse the output for specific information
# The URLs must return valid JSON for JQ to parse it and be of a similar format to those found below i.e. GitHub pages API output.
# Note, if you are running this script on MacOS, the BSD date command works differently. Use `gdate` to get the same output as below.

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

args=$(getopt -a -o t:c:u:p: --long slackBotToken:,slackChannelName:,help -- "$@")
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

if [[ -z "$slackBotToken" || -z "$slackChannelName" || -z "$snowUsername" || -z "$snowPassword" ]]; then
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
else
    STATUS=":green_circle:"
fi

# If there are more than 0 objects, print the object values into an array
if [ "$deletedResourceCount" -gt 0 ]; then
    failedDeletes=$(jq -r '.[].message | gsub("A resource failed to delete!\\\\nTo see why, you can run: az resource delete --ids "; "") | gsub("--verbose\\\\n"; "")' <<< $jsonData)
fi

# Post initial header message
slackNotification $slackBotToken $slackChannelName "$STATUS Orphaned Resource Status" "$deletedResourceCount resources failed to delete, <https://github.com/hmcts/dtspo-orphan-resources-cleanup/actions|*_Orphaned Delete Pipeline_*>"

# # Add any response to thread
if [ "$deletedResourceCount" -gt 0 ]; then
    slackThreadResponse $slackBotToken $slackChannelName "The following resources failed to delete, you can find more information by running \n \`az resource delete --ids "RESOURCE ID" --verbose\`" $TS
    slackThreadResponse $slackBotToken $slackChannelName "$failedDeletes" $TS
fi
