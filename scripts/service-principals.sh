#!/usr/bin/env bash

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

args=$(getopt -a -o t:c:d: --long slackBotToken:,slackChannelName:,checkDays:,help -- "$@")
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

az login --service-principal --username "${b2c_sbox_serviceprincipal_id}" --password "${b2c_sbox_serviceprincipal_password}" --tenant "${b2c_sbox_tenant_id}" --allow-no-subscriptions
if [ "$DOMAIN" = "hmctssboxextid.onmicrosoft.com" ]; then
# B2C Tenant Service Principal login 
echo "B2C Tenant login testing"
    AZ_APP_RESULT=$( az ad app list --display-name "B2C Tenants" --query "[?passwordCredentials[?endDateTime < '${CHECK_DATE}']].{displayName:displayName, appId:appId, createdDateTime:createdDateTime, passwordCredentials:passwordCredentials[?endDateTime < '${CHECK_DATE}'].{displayName:displayName,endDateTime:endDateTime}}" --output json )
    az login --identity
elif [ "$DOMAIN" = "HMCTS.NET" ]; then
az login --identity
    AZ_APP_RESULT=$( az ad app list --all --query "[?passwordCredentials[?endDateTime < '${CHECK_DATE}']].{displayName:displayName, appId:appId, createdDateTime:createdDateTime, passwordCredentials:passwordCredentials[?endDateTime < '${CHECK_DATE}'].{displayName:displayName,endDateTime:endDateTime}}" --output json )
else
    AZ_APP_RESULT=$( az ad app list --display-name "DTS Operations Bootstrap GA" --query "[?passwordCredentials[?endDateTime < '${CHECK_DATE}']].{displayName:displayName, appId:appId, createdDateTime:createdDateTime, passwordCredentials:passwordCredentials[?endDateTime < '${CHECK_DATE}'].{displayName:displayName,endDateTime:endDateTime}}" --output json )
fi

declare -a expiredApps=()
declare -a expiringAppsSoon=()
declare -a expiringAppsUrgent=()

azAppCount=$(jq -r '. | length' <<< "${AZ_APP_RESULT}")

if [[ $azAppCount -gt 0 ]]; then
    azAppData=$(jq -c '.[]' <<< "$AZ_APP_RESULT")

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
fi

STATUS=":green_circle:"
if [[ "${#expiredApps[@]}" -gt 0 || "${#expiringAppsUrgent[@]}" -gt 0 ]]; then
    STATUS=":red_circle:"
elif [ "${#expiringAppsSoon[@]}" -gt 0 ]; then
    STATUS=":yellow_circle:"
fi

function slackThread(){
    local message=""

    if [ "${#expiredApps[@]}" -gt 0 ]; then
        message+=":red_circle: Expired Service Principals found! \\n$(IFS=$'\n'; echo "${expiredApps[*]}")\\n\\n"
    fi

    if [ "${#expiringAppsUrgent[@]}" -gt 0 ]; then
        message+=":red_circle: Service Principals expiring very soon! \\n$(IFS=$'\n'; echo "${expiringAppsUrgent[*]}")\\n\\n"
    fi

    if [ "${#expiringAppsSoon[@]}" -gt 0 ]; then
        message+=":yellow_circle: Service Principals expiring soon! \\n$(IFS=$'\n'; echo "${expiringAppsSoon[*]}")\\n\\n"
    fi

    slackThreadResponse "$slackBotToken" "$slackChannelName" "$message" "$TS"
}

if [[ "$STATUS" == ":red_circle:" || "$STATUS" == ":yellow_circle:" ]]; then
    # Send slack header based on domain
    if [ $DOMAIN = "hmctssboxextid.onmicrosoft.com" ]; then
        # slackNotification $slackBotToken $slackChannelName ":azure-826: $STATUS Service Principal Checks - B2C Tenants" "<https://portal.azure.com/#view/Microsoft_AAD_B2CAdmin/TenantManagementMenuBlade/~/registeredApps|_*Service Principal Secrets Status - B2C Tenant*_>"
        slackNotification $slackBotToken $slackChannelName ":azure-826: $STATUS Service Principal Checks - B2C Tenants" "<https://portal.azure.com/#view/Microsoft_AAD_IAM/ActiveDirectoryMenuBlade/~/RegisteredApps|_*Service Principal Secrets Status - B2C Tenant*_>"
    elif [ $DOMAIN = "HMCTS.NET" ]; then
        slackNotification $slackBotToken $slackChannelName ":azure-826: $STATUS Service Principal Checks - HMCTS" "<https://portal.azure.com/#view/Microsoft_AAD_IAM/ActiveDirectoryMenuBlade/~/RegisteredApps|_*Service Principal Secrets Status*_>"    
    else
        slackNotification $slackBotToken $slackChannelName ":azure-826: $STATUS Service Principal Checks - HMCTS Dev" "<https://portal.azure.com/#view/Microsoft_AAD_IAM/ActiveDirectoryMenuBlade/~/RegisteredApps|_*Service Principal Secrets Status - HMCTS Dev Tenant*_>"
    fi
    # Send any output to slack thread
    slackThread
fi
