#!/usr/bin/env bash

#Script vars
RESOURCE_GROUP=$1
VAULT_NAME=$2
first_run="true"

RESOURCE_GROUP_EXIST=$( az group exists --name $RESOURCE_GROUP )

if [[ $RESOURCE_GROUP_EXIST == false ]]; then
    echo "$RESOURCE_GROUP does not exist"
    exit 0
fi

AZ_BACKUP_RESULT=$( az backup job list --resource-group $RESOURCE_GROUP --vault-name $VAULT_NAME --output json )

jq -c '.[]' <<< $AZ_BACKUP_RESULT | while read job_data; do
    job_status=$(jq -r '.properties.status' <<< "$job_data")
    vm_name=$(jq -r '.properties.entityFriendlyName' <<< "$job_data")
    vault_url_full=$(jq -r '.id' <<< "$job_data")
    parsed_vault_url="${vault_url_full::-37}"

    if [[ $job_status == "Failed" ]]; then
        printf "\n>:red_circle:  *$vm_name* backup in <https://portal.azure.com/#@HMCTS.NET/resource$parsed_vault_url|_*$VAULT_NAME*_> has $job_status" >> slack-message.txt
    elif [[ $first_run == "true" ]] && [[ $job_status != "Failed" ]]; then
        printf "\n>:green_circle:  No failed backups in <https://portal.azure.com/#@HMCTS.NET/resource$parsed_vault_url|_*$VAULT_NAME*_>" >> slack-message.txt
        first_run="false"
    fi
done
printf "\n"  >> slack-message.txt