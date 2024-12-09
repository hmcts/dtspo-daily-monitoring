#!/usr/bin/env bash

### Setup script environment
set -euo pipefail

# Source central functions script
source scripts/common-functions.sh

#Vars
slackBotToken=
slackChannelName=
failedState=()

usage() {
    cat >&2 <<EOF
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

autoFixCluster() {
    az resource update --ids $1
    cluster_status_recheck=$(az graph query -q "resources | where type =~ 'Microsoft.ContainerService/managedClusters'| where name == '$2'| project properties.provisioningState" -o json)
}

args=$(getopt -a -o t:c:p:g: --long slackBotToken:,slackChannelName:,help -- "$@")
if [[ $? -gt 0 ]]; then
    usage
fi

eval set -- ${args}
while :; do
    case $1 in
    -h | --help)
        usage
        shift
        ;;
    -t | --slackBotToken)
        slackBotToken=$2
        shift 2
        ;;
    -c | --slackChannelName)
        slackChannelName=$2
        shift 2
        ;;
    # -- means the end of the arguments; drop this, and break out of the while loop
    --)
        shift
        break
        ;;
    *)
        echo >&2 Unsupported option: $1
        usage
        ;;
    esac
done

if [[ -z "$slackBotToken" || -z "$slackChannelName" ]]; then
    {
        echo "------------------------"
        echo 'Please supply all of'
        echo '- Slack token'
        echo '- Slack channel name' >&2
        echo "------------------------"
        exit 1
    } >&2
    exit 1
fi

CLUSTERS=$(az graph query -q "resources | where type =~ 'Microsoft.ContainerService/managedClusters'| where tags.application == 'core'| project name, resourceGroup, properties, ['id']" --first 1000 -o json)

while read cluster; do
    RESOURCE_GROUP=$(jq -r '.resourceGroup' <<<$cluster)
    cluster_name=$(jq -r '.name' <<<$cluster)
    resourceId=$(jq -r '.id' <<<$cluster)
    cluster_status=$(jq -r '.provisioningState' <<<"$cluster")

    if [[ $cluster_status == "Failed" ]]; then
        autoFixCluster $resourceId $cluster_name
        
        #if cluster is still in a failed state after recheck, add to failedState array
        if [[ $cluster_status_recheck == "Failed" ]]; then
            failedState+="\n>:red_circle: <https://portal.azure.com/#@HMCTS.NET/resource$cluster_id|_*$cluster_name*_> has a provisioning state of $cluster_status"
            failures_exist="true"
        fi
    fi
done < <(jq -c '.data[]' <<<$CLUSTERS) # end_of_cluster_loop

# Default to green if the variable doesn't exist
checkStatus=":green_circle:"
if [ -n "${failures_exist+x}" ]; then        # Check if variable exists
    if [ "$failures_exist" == "true" ]; then #Check if the value is "true"
        checkStatus=":red_circle:"
    fi
fi

if [[ "$checkStatus" == ":red_circle:" ]]; then
    # Send initial header message
    slackNotification $slackBotToken $slackChannelName "$checkStatus AKS Cluster State Checks" " "

    # Loop through each failure
    for failure in "${failedState[@]}"; do
        slackThreadResponse $slackBotToken $slackChannelName "$failure" $TS
    done
fi
