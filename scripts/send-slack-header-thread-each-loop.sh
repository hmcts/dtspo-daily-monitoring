#!/usr/bin/env bash

# This script is used to send headers and message threads for checks that use each loops in Azure DevOps pipelines.
# When using each loops in Azure DevOps the output of each iteration should store results in a file
# That file can then be supplied to this script to send as a thread to Slack via this script

### Setup script environment
set -eo pipefail

# Source central functions script
source scripts/common-functions.sh

slackBotToken=
slackChannelName=
inputFileName=
messageHeader=
subHeading=" "

usage(){
>&2 cat << EOF
    ------------------------------------------------
    Script to check GitHub page expiry
    ------------------------------------------------
    Usage: $0
        [ -t | --slackBotToken ]
        [ -c | --slackChannelName ]
        [ -i | --inputFileName ]
        [ -m | --messageHeader ]
        [ -s | --subheading ]
        [ -h | --help ]
EOF
exit 1
}

args=$(getopt -a -o t:c:i:m:s:h: --long slackBotToken:,slackChannelName:,inputFileName:,messageHeader:,subheading:,help -- "$@")
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
        -s | --inputFileName)     inputFileName=$2         ; shift 2 ;;
        -m | --messageHeader)     messageHeader=$2         ; shift 2 ;;
        -s | --subheading)        subheading=$2            ; shift 2 ;;
        # -- means the end of the arguments; drop this, and break out of the while loop
        --) shift; break ;;
        *) >&2 echo Unsupported option: $1
            usage ;;
    esac
done

if [[ -z "$slackBotToken" || -z "$slackChannelName" || -z "$inputFileName" || -z "$messageHeader" ]]; then
    {
        echo "------------------------"
        echo 'Please supply all of: '
        echo '- Slack token'
        echo '- Slack channel name'
        echo '- Input Filename'
        echo '- Message Header Text'
        echo "------------------------"
    } >&2
    exit 1
fi

MESSAGE=$(cat $inputFileName)

# Only send output if red or yellow status
if [[ $MESSAGE == *":red_circle:"* ]]; then
    STATUS=":red_circle:"
    slackNotification $slackBotToken $slackChannelName "$STATUS $messageHeader" "$subHeading"
    slackThreadResponse "$slackBotToken" "$slackChannelName" "$MESSAGE" "$TS"
elif [[ $MESSAGE == *":yellow_circle:"* ]]; then
    STATUS=":yellow_circle:"
    slackNotification $slackBotToken $slackChannelName "$STATUS $messageHeader" "$subHeading"
    slackThreadResponse "$slackBotToken" "$slackChannelName" "$MESSAGE" "$TS"
fi
