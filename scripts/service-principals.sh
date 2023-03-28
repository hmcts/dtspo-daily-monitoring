set -ex

CHECK_DAYS=$1

TODAY_DATE=$(date +%Y-%m-%d)

CHECK_DATE=$(date -d "+${CHECK_DAYS} days" +%Y-%m-%d)


AZ_APP_RESULT=$( az ad app list --all --query "[?passwordCredentials[?endDateTime > '${TODAY_DATE}' && endDateTime < '${CHECK_DATE}']].{displayName:displayName, appId:appId, createdDateTime:createdDateTime, passwordCredentials:passwordCredentials[*].{displayName:displayName,endDateTime:endDateTime}}" --output json )

#AZ_APP_RESULT=$( az ad app list --all --query "[?passwordCredentials[?endDateTime > '2023-03-28' && endDateTime < '2023-10-14']].{displayName:displayName, appId:appId, createdDateTime:createdDateTime, passwordCredentials:passwordCredentials[*].{displayName:displayName,endDateTime:endDateTime}}" --output json )

AZ_APP_COUNT=$(jq -r '. | length' <<< "${AZ_APP_RESULT}")

if [[ $AZ_APP_COUNT == 0 ]]; then
    echo "None Service Principals Secrets are expiring in $CHECK_DAYS days"
    exit 0
fi

printf "\n:azure-826: <https://portal.azure.com/#view/Microsoft_AAD_IAM/ActiveDirectoryMenuBlade/~/RegisteredApps|_*Service Principal Secrets Status*_> \n\n" >> slack-message.txt

echo "$AZ_APP_RESULT" | jq -c -r '.[]'  | while read i; do
    displayName=$(jq -r '.displayName' <<< "$i")
    appId=$(jq -r '.appId' <<< "$i")
    APP_URL="https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/Credentials/appId/$appId"
    printf "\n:yellow_circle: <$APP_URL|_* $displayName *_> Secret Expiring within next $CHECK_DAYS days " >> slack-message.txt
done

