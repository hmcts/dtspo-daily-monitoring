set -ex

CHECK_DAYS=$1

TODAY_DATE=$(date +%Y-%m-%d)

CHECK_DATE=$(date -d "+${CHECK_DAYS} days" +%Y-%m-%d)

DOMAIN=$(az rest --method get --url https://graph.microsoft.com/v1.0/domains --query 'value[?isDefault].id' -o tsv)

if [ $DOMAIN = "HMCTS.NET" ]; then
    AZ_APP_RESULT=$( az ad app list --all --query "[?passwordCredentials[?endDateTime < '${CHECK_DATE}']].{displayName:displayName, appId:appId, createdDateTime:createdDateTime, passwordCredentials:passwordCredentials[?endDateTime < '${CHECK_DATE}'].{displayName:displayName,endDateTime:endDateTime}}" --output json )
else
    AZ_APP_RESULT=$( az ad app list --display-name "DTS Operations Bootstrap GA" --query "[?passwordCredentials[?endDateTime < '${CHECK_DATE}']].{displayName:displayName, appId:appId, createdDateTime:createdDateTime, passwordCredentials:passwordCredentials[?endDateTime < '${CHECK_DATE}'].{displayName:displayName,endDateTime:endDateTime}}" --output json )
fi

AZ_APP_COUNT=$(jq -r '. | length' <<< "${AZ_APP_RESULT}")

if [ $DOMAIN = "HMCTS.NET" ]; then
    printf "\n:azure-826: <https://portal.azure.com/#view/Microsoft_AAD_IAM/ActiveDirectoryMenuBlade/~/RegisteredApps|_*Service Principal Secrets Status*_> \n" >> slack-message.txt
else
    printf "\n:azure-826: <https://portal.azure.com/#view/Microsoft_AAD_IAM/ActiveDirectoryMenuBlade/~/RegisteredApps|_*Service Principal Secrets Status - HMCTS Dev Tenant*_> \n" >> slack-message.txt
fi

if [[ $AZ_APP_COUNT == 0 ]]; then
    printf "\n:green_circle: No Service Principals Secrets are expiring in $CHECK_DAYS days \n\n" >> slack-message.txt
    exit 0
fi

echo "$AZ_APP_RESULT" | jq -c -r '.[]'  | while read i; do
    displayName=$(jq -r '.displayName' <<< "$i")
    appId=$(jq -r '.appId' <<< "$i")
    endDateTime=$(jq -r '.passwordCredentials[0].endDateTime' <<< "$i")
    
    convert_date=$(date -d "$endDateTime" +%Y-%m-%d)
    date_diff=$(( ($(date -d "$convert_date UTC" +%s) - $(date -d "UTC" +%s) )/(60*60*24) ))
    

    APP_URL="https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/Credentials/appId/$appId"
    if [ $((date_diff)) -lt 0 ]; then
        printf "\n>:red_circle: <$APP_URL|_* $displayName*_> has expired" >> slack-message.txt
    elif [[ $((date_diff)) -gt 7 ]]; then
        printf "\n>:yellow_circle: <$APP_URL|_* $displayName*_> expires in $date_diff days" >> slack-message.txt
    else
        printf "\n>:red_circle: <$APP_URL|_* $displayName*_> expires in $date_diff days" >> slack-message.txt
    fi

done
printf "\n\n"  >> slack-message.txt
