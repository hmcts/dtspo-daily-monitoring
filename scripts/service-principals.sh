set -ex

CHECK_DAYS=$1

TODAY_DATE=$(gdate +%Y-%m-%d)

CHECK_DATE=$(gdate -d "+${CHECK_DAYS} days" +%Y-%m-%d)


AZ_APP_RESULT=$( az ad app list --all --query "[?passwordCredentials[?endDateTime > '${TODAY_DATE}' && endDateTime < '${CHECK_DATE}']].{displayName:displayName, appId:appId, createdDateTime:createdDateTime, passwordCredentials:passwordCredentials[?endDateTime > '${TODAY_DATE}' && endDateTime < '${CHECK_DATE}'].{displayName:displayName,endDateTime:endDateTime}}" --output json )

#AZ_APP_RESULT=$( az ad app list --all --query "[?passwordCredentials[?endDateTime > '2023-03-28' && endDateTime < '2023-04-29']].{displayName:displayName, appId:appId, createdDateTime:createdDateTime, passwordCredentials:passwordCredentials[?endDateTime > '2023-03-28' && endDateTime < '2023-04-29'].{displayName:displayName,endDateTime:endDateTime}}" --output json )

AZ_APP_COUNT=$(jq -r '. | length' <<< "${AZ_APP_RESULT}")

if [[ $AZ_APP_COUNT == 0 ]]; then
    printf "\n:green_circle: None Service Principals Secrets are expiring in $CHECK_DAYS days \n\n" >> slack-message.txt
    exit 0
fi

printf "\n:azure-826: <https://portal.azure.com/#view/Microsoft_AAD_IAM/ActiveDirectoryMenuBlade/~/RegisteredApps|_*Service Principal Secrets Status*_> \n" >> slack-message.txt

echo "$AZ_APP_RESULT" | jq -c -r '.[]'  | while read i; do
    displayName=$(jq -r '.displayName' <<< "$i")
    appId=$(jq -r '.appId' <<< "$i")
    endDateTime=$(jq -r '.passwordCredentials[].endDateTime' <<< "$i")
    
    convert_date=$(gdate -d "$endDateTime" +%Y-%m-%d)
    date_diff=$(( ($(gdate -d "$convert_date UTC" +%s) - $(gdate -d "2023-03-28 UTC" +%s) )/(60*60*24) ))
    

    APP_URL="https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/Credentials/appId/$appId"
    if [[ $((date_diff)) -gt 7 ]]; then
        printf "\n:yellow_circle: <$APP_URL|_* $displayName *_> Secret Expiring in next $date_diff days \n\n" >> slack-message.txt
    else
        printf "\n:red_circle: <$APP_URL|_* $displayName *_> Secret Expiring in next $date_diff days \n\n" >> slack-message.txt
    fi

done
