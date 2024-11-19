#!/usr/bin/env bash

# This script will download the latest output from the orphaned resource deletion repository that contains any resources that could not be deleted.
# This will then be sent to Slack in the Daily Checks channel for easier monitoring by all teams.

### Setup script environment
set -euo pipefail

# Source central functions script
source scripts/common-functions.sh

slackBotToken=
slackChannelName=
token=

usage(){
>&2 cat << EOF
------------------------------------------------
Script to check GitHub page expiry
------------------------------------------------
Usage: $0
    [ -t | --slackBotToken ]
    [ -c | --slackChannelName ]
    [ -n | --token ]
    [ -h | --help ]
EOF
exit 1
}

args=$(getopt -a -o t:c:n:h: --long slackBotToken:,slackChannelName:,token:,help -- "$@")
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
        -n | --token)             token=$2                 ; shift 2 ;;
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
        echo '- token'
        echo "------------------------"
    } >&2
    exit 1
fi


RESULT=$(curl -X GET https://app.launchdarkly.com/api/v2/members -H "Authorization: ${token}")
CONSUMED_LICENSES=$(jq -r .totalCount <<< "${RESULT}")
TOTAL_LICENSES=150 #None of the public APIs seem to return the number of licenses we have.

LICENSES_LEFT=$((TOTAL_LICENSES-CONSUMED_LICENSES))

LICENSE_STATUS=":red_circle:"
if (( "$LICENSES_LEFT" >= 25 )); then
  LICENSE_STATUS=":green_circle:"
elif ((  "$LICENSES_LEFT" >= 10 )); then
  LICENSE_STATUS=":yellow_circle:"
fi

slackNotification $slackBotToken $slackChannelName ":launchdarkly: $LICENSE_STATUS Launch Darkly License Check"  "<https://app.launchdarkly.com/settings/members|_*LaunchDarkly Licenses*_> _*$LICENSES_LEFT*_ out of *$TOTAL_LICENSES* licenses left"
