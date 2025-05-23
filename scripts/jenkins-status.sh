#!/usr/bin/env bash

### Setup script environment
set -exuo pipefail

# Source central functions script
source scripts/common-functions.sh

slackBotToken=
slackChannelName=
jenkinsUsername=
jenkinsApiToken=
jenkinsURL=

usage(){
>&2 cat << EOF
    ------------------------------------------------
    Script to check GitHub page expiry
    ------------------------------------------------
    Usage: $0
        [ -t | --slackBotToken ]
        [ -c | --slackChannelName ]
        [ -j | --jenkinsUsername ]
        [ -a | --jenkinsApiToken ]
        [ -u | --jenkinsURL ]
        [ -h | --help ]
EOF
exit 1
}

args=$(getopt -a -o t:c:j:a:u:h: --long slackBotToken:,slackChannelName:,jenkinsUsername:,jenkinsApiToken:,jenkinsURL:,help -- "$@")
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
        -j | --jenkinsUsername)   jenkinsUsername=$2       ; shift 2 ;;
        -t | --jenkinsApiToken)   jenkinsApiToken=$2       ; shift 2 ;;
        -u | --jenkinsURL)        jenkinsURL=$2            ; shift 2 ;;
        # -- means the end of the arguments; drop this, and break out of the while loop
        --) shift; break ;;
        *) >&2 echo Unsupported option: $1
            usage ;;
    esac
done

if [[ -z "$slackBotToken" || -z "$slackChannelName" || -z "$jenkinsUsername" || -z "$jenkinsApiToken" || -z "$jenkinsURL" ]]; then
    {
      echo "------------------------"
      echo 'Please supply all of: '
      echo '- Slack token'
      echo '- Slack channel name'
      echo '- Jenkins Username'
      echo '- Jenkins API Token'
      echo '- Jenkins URL'
      echo "------------------------"
    } >&2
    exit 1
fi

BUILD_QUEUE_RESULT=$( curl -u "$jenkinsUsername":"$jenkinsApiToken" "$jenkinsURL/queue/api/json")
BUILD_QUEUE_COUNT=$(jq -r '.items | length' <<< "$BUILD_QUEUE_RESULT")

BUILD_QUEUE_STATUS=":red_circle:"
if (( "$BUILD_QUEUE_COUNT" <= 75 )); then
  BUILD_QUEUE_STATUS=":green_circle:"
elif (( "$BUILD_QUEUE_COUNT" <= 125 )); then
  BUILD_QUEUE_STATUS=":yellow_circle:"
fi

DASHBOARD_RESULT=$( curl -u $jenkinsUsername:$jenkinsApiToken "$jenkinsURL/view/Platform/api/json?depth=1")

count=$(jq -r '.jobs | length' <<< $DASHBOARD_RESULT)

BUILD_STATUS_RESULTS=()
for ((i=0; i< ${count}; i++)); do
    URL=$(jq -r '.jobs['$i'].url' <<< "$DASHBOARD_RESULT")
    COLOR=$(jq -r '.jobs['$i'].color' <<< "$DASHBOARD_RESULT")
    FULL_DISPLAY_NAME=$(jq -r '.jobs['$i'].fullDisplayName' <<< "$DASHBOARD_RESULT" | sed -e "s/»/:/g")

    BUILD_STATUS=":yellow_circle:"
    if [[ "$COLOR" == "red" ]]; then
    BUILD_STATUS=":red_circle:"
    elif [[ "$COLOR" == "blue" ]]; then
    BUILD_STATUS=":green_circle:"
    fi

    BUILD_STATUS_RESULTS+=("$BUILD_STATUS <$URL|$FULL_DISPLAY_NAME>")
done

STATUS=":green_circle:"
for result in "${BUILD_STATUS_RESULTS[@]}"; do
    if [[ "$result" == *"red_circle"* ]]; then
      STATUS=":red_circle:"
      break
    elif [[ "$result" == *"yellow_circle"* ]]; then
      STATUS=":yellow_circle:"
    fi
done

# Send Slack notification only if CHECK_STATUS is red or yellow
if [[ "$STATUS" == ":red_circle:" || "$STATUS" == ":yellow_circle:" ]]; then
  # Post initial header message
  slackNotification $slackBotToken $slackChannelName ":jenkins: $STATUS  Jenkins Status" "$BUILD_QUEUE_STATUS _Build Queue :_ *$BUILD_QUEUE_COUNT* :sign-queue:"
  #Dashboard Status
  slackThreadResponse $slackBotToken $slackChannelName "_Dashboard Status:_\n$(printf "%s\n" "${BUILD_STATUS_RESULTS[@]}")" $TS
fi

