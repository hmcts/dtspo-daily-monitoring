#!/usr/bin/env bash

### Setup script environment
set -euo pipefail

# Source central functions script
source scripts/common-functions.sh

#Vars
slackBotToken=
slackChannelName=
failedState=()

usage(){
>&2 cat << EOF
------------------------------------------------
Script to check GitHub page expiry
------------------------------------------------
Usage: $0
    [ -t | --slackBotToken ]
    [ -c | --slackChannelName ]
    [ -h | --help ]
EOF
exit 1
}

args=$(getopt -a -o t:c:p:g: --long slackBotToken:,slackChannelName:,help -- "$@")
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
        # -- means the end of the arguments; drop this, and break out of the while loop
        --) shift; break ;;
        *) >&2 echo Unsupported option: $1
            usage ;;
    esac
done

if [[ -z "$slackBotToken" || -z "$slackChannelName" ]]; then
    echo "------------------------"
    echo 'Please supply a Slack token and a Slack channel name' >&2
    echo "------------------------"
    exit 1
fi

SUBSCRIPTIONS=$(az account list -o json)
while read subscription; do
    SUBSCRIPTION_ID=$(jq -r '.id' <<< $subscription)
    az account set -s $SUBSCRIPTION_ID
    CLUSTERS=$(az resource list --resource-type Microsoft.ContainerService/managedClusters --query "[?tags.application == 'core']" -o json)

    while read cluster; do
        RESOURCE_GROUP=$(jq -r '.resourceGroup' <<< $cluster)
        cluster_name=$(jq -r '.name' <<< $cluster)

        cluster_data=$(az aks show -n $cluster_name -g $RESOURCE_GROUP -o json)
        cluster_status=$(jq -r '.provisioningState' <<< "$cluster_data")
        cluster_id=$(jq -r '.id' <<< "$cluster_data")

        if [[ $cluster_status == "Failed" ]]; then
            failedState+="\n>:red_circle: <https://portal.azure.com/#@HMCTS.NET/resource$cluster_id|_*$cluster_name*_> has a provisioning state of $cluster_status"
            failures_exist="true"
        fi
    done < <(jq -c '.[]' <<< $CLUSTERS) # end_of_cluster_loop

done < <(jq -c '.[]' <<< $SUBSCRIPTIONS)

if [ $failures_exist ]; then
    status=":red_circle"
else
    status=":green_circle"
fi

# Send initial header message
slackNotification $slackBotToken $slackChannelName "$status AKS Cluster State Checks" " "

# Check Toffee failures and if exist, add to thread
if [ ${#failedState[@]} -eq 0 ]; then
    slackThreadResponse $slackBotToken $slackChannelName "\n>:green_circle:  All clusters have a provisioning state of: Succeeded" $TS
else
    # Loop through each failure
    for failure in "${failedState[@]}"; do
        slackThreadResponse $slackBotToken $slackChannelName "$failure" $TS
    done
fi
