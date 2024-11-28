#!/usr/bin/env bash

### Setup script environment
set -e

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
vaultId=$(az backup vault show --resource-group $resourceGroup --name $backupVault --query "id" -o tsv)
vaultURL="https://portal.azure.com/#@HMCTS.NET/resource$vaultId"
backupDetails=$( az backup item list --resource-group $resourceGroup --vault-name $backupVault --output json | jq -c '.[]')

# Initialize variables
slackThread=""

# Initialize arrays
failedBackups=()

#Loop over backup job json data
for backups in $backupDetails; do
    job_status=$(jq -r '.properties.lastBackupStatus' <<< "$backup")
    vm_name=$(jq -r '.properties.friendlyName' <<< "$backup")

    #If backup job has failed, print vm name and vault name to slack message
    if [[ $job_status == "Failed" ]]; then
        echo "Backup failed for: $vm_name"
        failedBackups+=("$(printf "Backup for %s in vault <%s|_*%s*_> with status of: *%s*\\n" "${vm_name}" "${vaultURL}" "${backupVault}" "${job_status}")")
    fi
done

if [ "${#failedBackups[@]}" -gt 0 ]; then
    slackThread+=":red_circle: Backups failed for the following VMs! \\n$(IFS=$'\n'; echo "${failedBackups[*]}")\\n\\n"
else
    slackThread+=":tada: :green_circle: No failed backups in <$vaultURL|_*$backupVault*_>\\n\\n"
fi

echo $slackThread >> azurebackup-status.txt
