#!/usr/bin/env bash

### Setup script environment
set -euo pipefail

# Source central functions script
source scripts/common-functions.sh

resourceGroup=
backupVault=

usage(){
>&2 cat << EOF
    ------------------------------------------------
    Script to check GitHub page expiry
    ------------------------------------------------
    Usage: $0
        [ -r | --resourceGroup ]
        [ -v | --backupVault ]
        [ -h | --help ]
EOF
exit 1
}

args=$(getopt -a -o r:v:h: --long resourceGroup:,backupVault:,help -- "$@")
if [[ $? -gt 0 ]]; then
    usage
fi

eval set -- ${args}
while :
do
    case $1 in
        -h | --help)           usage             ; shift   ;;
        -r | --resourceGroup)  resourceGroup=$2  ; shift 2 ;;
        -v | --backupVault)    backupVault=$2    ; shift 2 ;;
        -d | --checkDays)      checkDays=$2      ; shift 2 ;;
        # -- means the end of the arguments; drop this, and break out of the while loop
        --) shift; break ;;
        *) >&2 echo Unsupported option: $1
            usage ;;
    esac
done

if [[ -z "$resourceGroup" || -z "$backupVault" ]]; then
    {
        echo "------------------------"
        echo 'Please supply all of: '
        echo '- Resource Group name'
        echo '- Recovery Service Vault name'
        echo "------------------------"
    } >&2
    exit 1
fi

#check if resource group exists
rgExists=$( az group exists --name $resourceGroup )

if [[ $rgExists == false ]]; then
    echo "$resourceGroup does not exist"
    exit 0
fi

#Get backup items json from recovery services vault
backupDetails=$( az backup item list --resource-group $resourceGroup --vault-name $backupVault --output json )

# Initialize variables
slackThread=""

# Initialize arrays
failedBackups=()

#Loop over backup job json data
while read backup; do
    job_status=$(jq -r '.properties.lastBackupStatus' <<< "$backup")
    vm_name=$(jq -r '.properties.friendlyName' <<< "$backup")
    vaultId=$(jq -r '.properties.vaultId' <<< "$backup")

    #Pointing URL to public portal
    parsed_vault_url=${vaultId/management.azure.com/portal.azure.com/#@HMCTS.NET/resource}

    #If backup job has failed, print vm name and vault name to slack message
    if [[ $job_status == "Failed" ]]; then
        echo "Backup failed for: $vm_name"
        failedBackups+=("$(printf "Backup for %s in vault <%s|_*%s*_> with status of: *%s*%\\n" "${vm_name}" "${parsed_vault_url}" "${backupVault}" "${job_status}")")
    fi
done < <(jq -c '.[]' <<< $backupDetails)

if [ "${#failedBackups[@]}" -gt 0 ]; then
    slackThread+=":red_circle: Backups failed for the following VMs! \\n$(IFS=$'\n'; echo "${failedBackups[*]}")\\n\\n"
else
    slackThread+=":tada: :green_circle: No failed backups in <$parsed_vault_url|_*$backupVault*_>\\n\\n"
fi

echo $slackThread >> azurebackup-status.txt
