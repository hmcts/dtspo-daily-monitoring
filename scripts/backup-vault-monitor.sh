#!/usr/bin/env bash

# Checks for failed backup jobs in an Azure Backup Vault over the past 8 days.
# Only runs on Mondays to align with the weekly backup schedule.
# Sends a Slack notification directly if failures are found, or a green status if all is well.

### Setup script environment
set -euo pipefail

# Source central functions script
source scripts/common-functions.sh

slackBotToken=
slackChannelName=
resourceGroup=
backupVault=

usage(){
>&2 cat << EOF
    ------------------------------------------------
    Script to check Azure Backup Vault job status
    ------------------------------------------------
    Usage: $0
        [ -t | --slackBotToken ]
        [ -c | --slackChannelName ]
        [ -r | --resourceGroup ]
        [ -v | --backupVault ]
        [ -h | --help ]
EOF
exit 1
}

args=$(getopt -a -o t:c:r:v:h --long slackBotToken:,slackChannelName:,resourceGroup:,backupVault:,help -- "$@")
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
        -r | --resourceGroup)     resourceGroup=$2         ; shift 2 ;;
        -v | --backupVault)       backupVault=$2           ; shift 2 ;;
        # -- means the end of the arguments; drop this, and break out of the while loop
        --) shift; break ;;
        *) >&2 echo Unsupported option: $1
            usage ;;
    esac
done

if [[ -z "$slackBotToken" || -z "$slackChannelName" || -z "$resourceGroup" || -z "$backupVault" ]]; then
    {
        echo "------------------------"
        echo 'Please supply all of: '
        echo '- Slack token'
        echo '- Slack channel name'
        echo '- Resource Group name'
        echo '- Backup Vault name'
        echo "------------------------"
    } >&2
    exit 1
fi

# Only run on Mondays (day 1 in ISO week: Mon=1 ... Sun=7)
DAY_OF_WEEK=$(date +%u)
if [[ "$DAY_OF_WEEK" != "1" ]]; then
    echo "Backup vault check skipped — only runs on Mondays (today is day $DAY_OF_WEEK)"
    exit 0
fi

### Script begins

vaultId=$(az dataprotection backup-vault show \
    --resource-group "$resourceGroup" \
    --vault-name "$backupVault" \
    --query "id" -o tsv)

vaultURL="https://portal.azure.com/#@HMCTS.NET/resource${vaultId}"

# Fetch all backup jobs
allJobs=$(az dataprotection job list \
    --resource-group "$resourceGroup" \
    --vault-name "$backupVault" \
    --output json)

# Filter to failed backup jobs only
failedJobs=$(echo "$allJobs" | jq '[.[] | select(.properties.status == "Failed" and .properties.operationCategory == "Backup")]')
failedCount=$(echo "$failedJobs" | jq 'length')

if [[ "$failedCount" -gt 0 ]]; then
    slackNotification "$slackBotToken" "$slackChannelName" \
        ":red_circle: Azure Backup Vault Failed Jobs" \
        ":azure_backup: Backup failures detected in <${vaultURL}|_*${backupVault}*_>:"

    while read -r job; do
        instance=$(echo "$job"  | jq -r '.properties.dataSourceName')
        started=$(echo "$job"   | jq -r '.properties.startTime')
        errorCode=$(echo "$job" | jq -r '.properties.errorDetails[0].code // "Unknown"')

        slackThreadResponse "$slackBotToken" "$slackChannelName" \
            ":x: *${instance}* failed on ${started} — \`${errorCode}\`" \
            "$TS"
    done < <(echo "$failedJobs" | jq -c '.[]')
else
    slackNotification "$slackBotToken" "$slackChannelName" \
        ":green_circle: Azure Backup Vault" \
        ":azure_backup: No failed backup jobs in <${vaultURL}|_*${backupVault}*_> :tada:"
fi
