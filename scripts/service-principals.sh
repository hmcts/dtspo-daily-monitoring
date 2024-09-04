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
checkDays=

usage(){
>&2 cat << EOF
------------------------------------------------
Script to check GitHub page expiry
------------------------------------------------
Usage: $0
    [ -t | --slackBotToken ]
    [ -c | --slackChannelName ]
    [ -d | --checkDays ]
    [ -h | --help ]
EOF
exit 1
}

args=$(getopt -a -o t:c:p:g: --long slackBotToken:,slackChannelName:,checkDays:,help -- "$@")
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
        -d | --checkDays)         checkDays=$2             ; shift 2 ;;
        # -- means the end of the arguments; drop this, and break out of the while loop
        --) shift; break ;;
        *) >&2 echo Unsupported option: $1
            usage ;;
    esac
done

if [ -z "$slackBotToken" || -z "$slackChannelName" || -z "$checkDays" ]; then
        echo "------------------------"
        echo 'Please supply all of Slack token, Slack channel name and Check Days' >&2
        echo "------------------------"
        exit 1
fi

TODAY_DATE=$(date_command +%Y-%m-%d)
CHECK_DATE=$(date_command -d "+${checkDays} days" +%Y-%m-%d)
DOMAIN=$(az rest --method get --url https://graph.microsoft.com/v1.0/domains --query 'value[?isDefault].id' -o tsv)

if [ $DOMAIN = "HMCTS.NET" ]; then
    AZ_APP_RESULT=$( az ad app list --all --query "[?passwordCredentials[?endDateTime < '${CHECK_DATE}']].{displayName:displayName, appId:appId, createdDateTime:createdDateTime, passwordCredentials:passwordCredentials[?endDateTime < '${CHECK_DATE}'].{displayName:displayName,endDateTime:endDateTime}}" --output json )
else
    AZ_APP_RESULT=$( az ad app list --display-name "DTS Operations Bootstrap GA" --query "[?passwordCredentials[?endDateTime < '${CHECK_DATE}']].{displayName:displayName, appId:appId, createdDateTime:createdDateTime, passwordCredentials:passwordCredentials[?endDateTime < '${CHECK_DATE}'].{displayName:displayName,endDateTime:endDateTime}}" --output json )
fi

if [ $DOMAIN = "HMCTS.NET" ]; then
    slackNotification $slackBotToken $slackChannelName ":azure-826: <https://portal.azure.com/#view/Microsoft_AAD_IAM/ActiveDirectoryMenuBlade/~/RegisteredApps|_*Service Principal Secrets Status*_>"
else
    slackNotification $slackBotToken $slackChannelName ":azure-826: <https://portal.azure.com/#view/Microsoft_AAD_IAM/ActiveDirectoryMenuBlade/~/RegisteredApps|_*Service Principal Secrets Status - HMCTS Dev Tenant*_>"
fi

AZ_APP_COUNT=$(jq -r '. | length' <<< "${AZ_APP_RESULT}")

declare -a expiredApps
declare -a expiringAppsSoon
declare -a expiringAppsUrgent

if [[ $AZ_APP_COUNT == 0 ]]; then
    slackNotification $slackBotToken $slackChannelName ":green_circle: No Service Principals Secrets are expiring in $checkDays days"
    exit 0
else
    echo "$AZ_APP_RESULT" | jq -c -r '.[]'  | while read i; do
        displayName=$(jq -r '.displayName' <<< "$i")
        appId=$(jq -r '.appId' <<< "$i")
        endDateTime=$(jq -r '.passwordCredentials[0].endDateTime' <<< "$i")

        convert_date=$(date_command -d "$endDateTime" +%Y-%m-%d)
        date_diff=$(( ($(date_command -d "$convert_date UTC" +%s) - $(date_command -d "UTC" +%s) )/(60*60*24) ))

        APP_URL="https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/Credentials/appId/$appId"
        if [ $((date_diff)) -lt 0 ]; then
            expiredApps+=("<$APP_URL|_* $displayName*_> has expired")
        elif [[ $((date_diff)) -gt 7 ]]; then
            expiringAppsSoon+=("<$APP_URL|_* $displayName*_> expires in $date_diff days")
        else
            expiringAppsUrgent+=("<$APP_URL|_* $displayName*_> expires in $date_diff days")
        fi
    done
fi

if [ ${#expiredApps[@]} -gt 0 ]; then
    slackNotification $slackBotToken $slackChannelName  ":red_circle: Expired Service Principals found!"
    slackThreadResponse $slackBotToken $slackChannelName "$(IFS=$'\n'; echo "${expiredApps[*]}")" $TS
fi

if [ ${#expiringAppsSoon[@]} -gt 0 ]; then
    slackNotification $slackBotToken $slackChannelName  ":yellow_circle: Service Principals expiring soon!"
    slackThreadResponse $slackBotToken $slackChannelName "$(IFS=$'\n'; echo "${expiringAppsSoon[*]}")" $TS
fi

if [ ${#expiringAppsUrgent[@]} -gt 0 ]; then
    slackNotification $slackBotToken $slackChannelName  ":red_circle: Service Principals expiring very soon!"
    slackThreadResponse $slackBotToken $slackChannelName "$(IFS=$'\n'; echo "${expiringAppsUrgent[*]}")" $TS
fi
