#!/usr/bin/env bash

### Setup script environment
set -euo pipefail

# Source central functions script
source scripts/common-functions.sh

slackBotToken=
slackChannelName=

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

args=$(getopt -a -o t:c:p:g: --long slackBotToken:,slackChannelName:,help -- "$@")
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
        echo 'Please supply all of'
        echo '- Slack token'
        echo '- Slack channel name' >&2
        echo "------------------------"
        exit 1
    } >&2
    exit 1
fi

### Script begins
CURRENTTIME=$($date_command +"%b %d %T") # 2w = 2 weeks
STATUS=":green_circle"
slackThread="This status check was run on: $CURRENTTIME \\n\\n "

# Declare any associative array
declare -A resourceTypes
declare -A statusOutputs

# Assign modes to the associative array resource types
resourceTypes[vm]="start deallocate"
resourceTypes[vmss]="start deallocate"
resourceTypes[appgateway]="start stop"
resourceTypes[blob-storage]="start stop"
resourceTypes[flexible-server]="start stop"
resourceTypes[sql]="start stop"

urlTemplate="https://raw.githubusercontent.com/hmcts/auto-shutdown/refs/heads/master/status/<replace>_status_updates_<mode>.json"

# Loop through each resource type
for resource in "${!resourceTypes[@]}"; do
    # Split the space-separated mode values into a temporary array called `modes`
    IFS=' ' read -r -a modes <<< "${resourceTypes[$resource]}"

    # Loop through each mode for the current resource type
    for mode in "${modes[@]}"; do
        # Replace <replace> and <mode> in the urlTemplate with the current resource type and mode
        url="${urlTemplate//<replace>/$resource}"
        url="${url//<mode>/$mode}"

        # Use curl to pull the JSON value from the URL and store it in the associative array with a key of resource+mode e.g. vm-start
        # If no file is found, fail silently and echo a blank value into the respective array
        statusOutputs["$resource-$mode"]=$(curl -sf $url | jq '.[].statusMessage '|| echo "")

        if [ "${#statusOutputs["$resource-$mode"]}" -gt 0 ]; then
            # printf "\\nStart content for %s: %s\\n" "$resource" "${startStatusOutputs[$resource]}"
            STATUS=":red_circle:"
            # slackThread+="$STATUS Issues found with $resource during $mode action! \\n Please visit the <$url|_*status output*_> for more information.\\n\\n"
            slackThread+=$(printf " %s Issues found with *%s* during *%s* action! Please visit the <%s|_*status output*_> for more information.\\n\\n " "$STATUS" "$resource" "$mode" "$url")
        fi
    done
done

# Send Slack notification only if CHECK_STATUS is red or yellow
if [[ "$STATUS" == ":red_circle:" ]]; then
    # Post initial header message
    slackNotification $slackBotToken $slackChannelName "$STATUS :clock1: Auto Shutdown Status" "You can visit the <https://github.com/hmcts/auto-shutdown/tree/master/status|_*Status Section*_> or <https://moj.enterprise.slack.com/archives/C07CL9KJHUN|_*Slack Channel*_> for more details"

    # Send slack Thread
    slackThreadResponse "$slackBotToken" "$slackChannelName" "$slackThread" "$TS"
fi
