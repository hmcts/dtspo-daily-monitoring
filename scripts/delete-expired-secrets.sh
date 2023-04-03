# set -ex

TODAY_DATE=$(gdate +%Y-%m-%d)


AZ_APP_RESULT=$( az ad app list --all  --query "[?passwordCredentials[?endDateTime < '${TODAY_DATE}']].{displayName:displayName, appId:appId, createdDateTime:createdDateTime, passwordCredentials:passwordCredentials[?endDateTime < '${TODAY_DATE}'].{keyId:keyId,displayName:displayName,endDateTime:endDateTime}}" --output json )

echo "$AZ_APP_RESULT" | jq -c -r '.[]'  | while read i; do
    appId=$(jq -r '.appId' <<< "$i")
    echo "appid: $appId"
    
    endDateTime=$(jq -r '.passwordCredentials[0].endDateTime' <<< "$i")
    keyId=$(jq -r '.passwordCredentials[0].keyId' <<< "$i")
    echo "keyid: $keyId"
    echo "endDateTime: $endDateTime"
    
    # az ad app credential delete --id $appId --key-id $keyId
done