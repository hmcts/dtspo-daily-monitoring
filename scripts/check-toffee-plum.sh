#!/usr/bin/env bash

### Setup script environment
set -euo pipefail

# Source central functions script
source scripts/common-functions.sh

slackBotToken=
slackChannelName=
failures_exist_toffee="false"
failures_exist_plum="false"

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
    echo "------------------------"
    echo 'Please supply a Slack token and a Slack channel name' >&2
    echo "------------------------"
    exit 1
fi

function add_environments() {
    if [[ "$1" == "Toffee" ]]; then
        ENVIRONMENTS=("Sandbox" "Test" "ITHC" "Demo" "Staging" "Prod")
    fi
    if [[ "$1" == "Plum" ]]; then
        ENVIRONMENTS=("Sandbox" "Perftest" "ITHC" "Demo" "AAT" "Prod")
    fi
}

function status_code() {
    if [ $ENV == "Prod" ]; then
        url="https://$1.platform.hmcts.net"
        statuscode=$(curl -s -o /dev/null -w "%{http_code}" $url)
    elif [ $ENV != "Prod" ]; then
        url="https://$1.$ENV.platform.hmcts.net"
        statuscode=$(curl -s -o /dev/null -w "%{http_code}" $url)
    fi
}

function failure_check() {
    if [[ $statuscode != 200 ]] && [[ $1 == "Toffee" ]]; then
        failure_msg_toffee+=">:red_circle:  <$url| $ENV> is unhealthy"
        failures_exist_toffee="true"
    elif [[ $statuscode != 200 ]] && [[ $1 == "Plum" ]]; then
        failure_msg_plum+=">:red_circle:  <$url| $ENV> is unhealthy"
        failures_exist_plum="true"
    fi
}

function uptime() {
    for ENV in ${ENVIRONMENTS[@]}; do
        status_code $1
        failure_check $1
    done
}

function check_status() {
    add_environments $1
    uptime $1
}

# hold any failure messages
failure_msg_toffee=()
failure_msg_plum=()

APPS=("Toffee" "Plum")

# Check app status first
for APP in ${APPS[@]}; do
    check_status $APP
done

if [[ $failures_exist_toffee || $failures_exist_plum ]]; then
    status=":red_circle"
else
    status=":green_circle"
fi

# Send initial header message
slackNotification $slackBotToken $slackChannelName "$status Toffee/Plum Status Checks" " "

# Check Toffee failures and if exist, add to thread
if [ ${#failure_msg_toffee[@]} -eq 0 ]; then
    slackThreadResponse $slackBotToken $slackChannelName ">:green_circle: All Toffee deployments are healthy" $TS
else
    # Loop through each failure
    for failure in "${failure_msg_toffee[@]}"; do
        slackThreadResponse $slackBotToken $slackChannelName "$failure" $TS
    done
fi

# Check Plum failures and if exist, add to thread
if [ ${#failure_msg_plum[@]} -eq 0 ]; then
    slackThreadResponse $slackBotToken $slackChannelName ">:green_circle: All Toffee deployments are healthy" $TS
else
    # Loop through each failure
    for failure in "${failure_msg_plum[@]}"; do
        slackThreadResponse $slackBotToken $slackChannelName "$failure" $TS
    done
fi

