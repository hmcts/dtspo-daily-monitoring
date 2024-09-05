#!/usr/bin/env bash

# This script will curl the output of the pages found in the URLS array and use JQ to parse the output for specific information
# The URLs must return valid JSON for JQ to parse it and be of a similar format to those found below i.e. GitHub pages API output.
# Note, if you are running this script on MacOS, the BSD date command works differently. Use `gdate` to get the same output as below.

### Setup script environment
set -euox pipefail

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

if [ -z "$slackBotToken" ] || [ -z "$slackChannelName" ] || [ -z "$checkDays" ]; then
        echo "------------------------"
        echo 'Please supply all of Slack token, Slack channel name and Check Days' >&2
        echo "------------------------"
        exit 1
fi

TODAY_DATE=$(date +%Y-%m-%d)
CHECK_DATE=$(date -d "+${checkDays} days" +%Y-%m-%d)
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

azAppCount=$(jq -r '. | length' <<< "${AZ_APP_RESULT}")
azAppData=$(jq -c '.[]' <<< "$AZ_APP_RESULT")

declare -a expiredApps=()
declare -a expiringAppsSoon=()
declare -a expiringAppsUrgent=()

if [[ $azAppCount == 0 ]]; then
    slackNotification $slackBotToken $slackChannelName "> :green_circle: No Service Principals Secrets are expiring in $checkDays days"
    exit 0
fi

while read -r app; do
    displayName=$(jq -r '.displayName' <<< "$app")
    appId=$(jq -r '.appId' <<< "$app")
    endDateTime=$(jq -r '.passwordCredentials[0].endDateTime' <<< "$app")

    convert_date=$(date -d "$endDateTime" +%Y-%m-%d)
    date_diff=$(( ($(date -d "$convert_date UTC" +%s) - $(date -d "UTC" +%s) )/(60*60*24) ))

    APP_URL="https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/Credentials/appId/$appId"
    if [ $((date_diff)) -lt 0 ]; then
        expiredApps+=("$(printf "<%s|_* %s*_> has expired" "${APP_URL}" "${displayName}")")
    elif [[ $((date_diff)) -gt 7 ]]; then
        expiringAppsSoon+=("$(printf "<%s|_* %s*_> expires in %d days" "$APP_URL" "$displayName" "$date_diff")")
    else
        expiringAppsUrgent+=("$(printf "<%s|_* %s*_> expires in %d days" "$APP_URL" "$displayName" "$date_diff")")
    fi
done <<< "$azAppData"

echo "${expiredApps[@]}"
echo "${expiringAppsSoon[@]}"
echo "${expiringAppsUrgent[@]}"

echo "${#expiredApps[@]}"
echo "${#expiringAppsSoon[@]}"
echo "${#expiringAppsUrgent[@]}"

if [ "${#expiredApps[@]}" -gt 0 ]; then
    slackNotification $slackBotToken $slackChannelName  "> :red_circle: Expired Service Principals found!"
    slackThreadResponse $slackBotToken $slackChannelName "$(IFS=$'\n'; echo "${expiredApps[*]}")" $TS
fi

if [ "${#expiringAppsSoon[@]}" -gt 0 ]; then
    slackNotification $slackBotToken $slackChannelName  "> :yellow_circle: Service Principals expiring soon!"
    slackThreadResponse $slackBotToken $slackChannelName "$(IFS=$'\n'; echo "${expiringAppsSoon[*]}")" $TS
fi

if [ "${#expiringAppsUrgent[@]}" -gt 0 ]; then
    slackNotification $slackBotToken $slackChannelName  "> :red_circle: Service Principals expiring very soon!"
    slackThreadResponse $slackBotToken $slackChannelName "$(IFS=$'\n'; echo "${expiringAppsUrgent[*]}")" $TS
fi