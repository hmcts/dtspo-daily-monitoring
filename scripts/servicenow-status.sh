#!/usr/bin/env bash

### Setup script environment
set -euo pipefail

# Source central functions script
source scripts/common-functions.sh

slackBotToken=
slackChannelName=
snowUsername=
snowPassword=

usage(){
>&2 cat << EOF
  ------------------------------------------------
  Script to check GitHub page expiry
  ------------------------------------------------
  Usage: $0
      [ -t | --slackBotToken ]
      [ -c | --slackChannelName ]
      [ -u | --snowUsername ]
      [ -p | --snowPassword ]
      [ -h | --help ]
EOF
exit 1
}

args=$(getopt -a -o t:c:u:p:h: --long slackBotToken:,slackChannelName:,snowUsername:,snowPassword:,help -- "$@")
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
        -u | --snowUsername)      snowUsername=$2          ; shift 2 ;;
        -p | --snowPassword)      snowPassword=$2          ; shift 2 ;;
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
        echo '- ServiceNow Username'
        echo '- ServiceNow Password'
        echo "------------------------"
    } >&2
    exit 1
fi

OPEN_INCIDENTS_RESULT=$( curl -u "$snowUsername":"$snowPassword" "https://mojcppprod.service-now.com/api/now/stats/incident?sysparm_count=true&sysparm_fields=number,state&sysparm_query=assignment_group=6e1f4d64db642b8046cc72dabf96195f^ORassignment_group=96636bdcdb6d334046cc72dabf961978^state!=6^state!=7")
OPEN_INCIDENTS_COUNT=$(jq -r .result.stats.count <<< "${OPEN_INCIDENTS_RESULT}")

OPEN_PROBLEMS_RESULT=$( curl -u "$snowUsername":"$snowPassword" "https://mojcppprod.service-now.com/api/now/stats/problem?sysparm_count=true&sysparm_fields=number,state&sysparm_query=assignment_group=6e1f4d64db642b8046cc72dabf96195f^ORassignment_group=96636bdcdb6d334046cc72dabf961978^state!=9^state!=4^state!=11")
OPEN_PROBLEMS_COUNT=$(jq -r .result.stats.count <<< "${OPEN_PROBLEMS_RESULT}")

OPEN_INCIDENTS_STATUS=":red_circle:"
if (( "$OPEN_INCIDENTS_COUNT" <= 10 )); then
  OPEN_INCIDENTS_STATUS=":green_circle:"
elif ((  "$OPEN_INCIDENTS_COUNT" <= 15 )); then
  OPEN_INCIDENTS_STATUS=":yellow_circle:"
fi

OPEN_PROBLEMS_STATUS=":red_circle:"
if (( "$OPEN_PROBLEMS_COUNT" <= 10 )); then
  OPEN_PROBLEMS_STATUS=":green_circle:"
elif ((  "$OPEN_PROBLEMS_COUNT" <= 15 )); then
  OPEN_PROBLEMS_STATUS=":yellow_circle:"
fi

snowStatus=":green_circle:"
if [[ "$OPEN_INCIDENTS_STATUS" == "red_circle" || "$OPEN_PROBLEMS_STATUS" == "red_circle" ]]; then
  snowStatus=":red_circle:"
elif [[ "$OPEN_INCIDENTS_STATUS" == "yellow_circle" || "$OPEN_PROBLEMS_STATUS" == "yellow_circle" ]]; then
  snowStatus=":yellow_circle:"
fi

if [[ "$snowStatus" == ":red_circle:" || "$snowStatus" == ":yellow_circle:" ]]; then
  # Post initial header message
  slackNotification $slackBotToken $slackChannelName ":service-now: $snowStatus Service Now Check" "<https://mojcppprod.service-now.com/|_*ServiceNow Status*_>"
  # Dashboard status heading
  slackThreadResponse $slackBotToken $slackChannelName "$OPEN_INCIDENTS_STATUS There are $OPEN_INCIDENTS_COUNT open incidents" $TS
  #Pipeline Status
  slackThreadResponse $slackBotToken $slackChannelName "$OPEN_PROBLEMS_STATUS There are $OPEN_PROBLEMS_COUNT open problems" $TS
fi
