#!/usr/bin/env bash

# This script will download the latest output from the orphaned resource deletion repository that contains any resources that could not be deleted.
# This will then be sent to Slack in the Daily Checks channel for easier monitoring by all teams.

### Setup script environment
set -eo pipefail

# Source central functions script
source scripts/common-functions.sh

subscription=

usage(){
>&2 cat << EOF
  ------------------------------------------------
  Script to check GitHub page expiry
  ------------------------------------------------
  Usage: $0
      [ -s | --subscription ]
      [ -h | --help ]
EOF
exit 1
}

args=$(getopt -a -o s:h: --long subscription:,help -- "$@")
if [[ $? -gt 0 ]]; then
    usage
fi

eval set -- ${args}
while :
do
    case $1 in
        -h | --help)              usage                    ; shift   ;;
        -s | --subscription)      subscription=$2          ; shift 2 ;;
        # -- means the end of the arguments; drop this, and break out of the while loop
        --) shift; break ;;
        *) >&2 echo Unsupported option: $1
            usage ;;
    esac
done

if [[ -z "$subscription" ]]; then
    {
        echo "---------------------------------"
        echo 'Please supply a subscription name'
        echo "---------------------------------"
    } >&2
    exit 1
fi

# Initialize variables
slackThread=""

# Initialize arrays
resourcesInUnreadyState=()
criticalCapacityResources=()
highCapacityResources=()

# Initialize counters
criticalCapacityResourcesCount=0
highCapacityResourcesCount=0
lowCapacityStorageUsageCount=0
resourcesInUnreadyStateCount=0

# Print initial message for the thread response to the initial heading message
slackThread+="\\n\\n"
slackThread+="PostgreSQL Flexible Server Storage Usage for subscription: $subscription\\n\\n"

# Pull information back from Azure that can be used for checks
POSTGRES_FLEXIBLE_INSTANCES=$(az postgres flexible-server list --subscription $subscription --query "[].{id: id, name: name, state: state}")
COUNT=$(echo $POSTGRES_FLEXIBLE_INSTANCES | jq '. | length')

# Loop through the instances found in the subscription to check their status, add to the relevant array determined by the check
# e.g. if storage capacity is 85% then add to the `highCapacityResources` array
for ((INDEX = 0; INDEX < $COUNT; INDEX++)); do
  INSTANCE_ID=$(echo $POSTGRES_FLEXIBLE_INSTANCES | jq -r '.['$INDEX'].id')
  INSTANCE_NAME=$(echo $POSTGRES_FLEXIBLE_INSTANCES | jq -r '.['$INDEX'].name')
  INSTANCE_STATE=$(echo $POSTGRES_FLEXIBLE_INSTANCES | jq -r '.['$INDEX'].state')

  echo "----- Processing: $INSTANCE_NAME -----"

  # If instance state is ready then run checks, if not add this to the `resourcesInUnreadyState` array for printing later
  if [ "$INSTANCE_STATE" == "Ready" ]; then
    INSTANCE_URL="https://portal.azure.com/#@HMCTS.NET/resource$INSTANCE_ID"
    STORAGE_USED=$(az monitor metrics list --resource "$INSTANCE_ID" --metric storage_percent --offset 0d6h --interval 6h | jq -r ".value[0].timeseries[0].data[0].average // 0 | round")
    if [ "$STORAGE_USED" -gt 95 ]; then
      echo "Storage capacity is currently at critical level"
      criticalCapacityResources+=("$(printf "<%s|_*%s*_> is at *%s*%%\\n" "${INSTANCE_URL}" "${INSTANCE_NAME}" "${STORAGE_USED}")")
      criticalCapacityResourcesCount=$(($criticalCapacityResourcesCount+1))
    elif [ "$STORAGE_USED" -gt 80 ]; then
      echo "Storage capacity is currently at high level"
      highCapacityResources+=("$(printf "<%s|_*%s*_> is at *%s*%%\\n" "${INSTANCE_URL}" "${INSTANCE_NAME}" "${STORAGE_USED}")")
      highCapacityResourcesCount=$(($highCapacityResourcesCount+1))
    else
      echo "Storage capacity within acceptable limits"
      lowCapacityStorageUsageCount=$(($lowCapacityStorageUsageCount+1))
    fi
  else
    echo "Server is not in a ready state!!"
    resourcesInUnreadyState+=("$(printf "_*%s*_ is in *%s* state.\\n" "${INSTANCE_NAME}" "${INSTANCE_STATE}")")
    resourcesInUnreadyStateCount=$(($resourcesInUnreadyStateCount+1))
  fi
done

# First message in the thread should show the number of servers in a good state
slackThread+=$(printf ":tada: :green_circle: *%s* PostgreSQL Flexible Servers are running below 80%% storage capacity.\\n\\n" "${lowCapacityStorageUsageCount}")

# Check if each of the arrays is empty, if not then add the relevant output to the slackThread variable to be sent to slack as a threaded update.
if [ "${#resourcesInUnreadyState[@]}" -gt 0 ]; then
    slackThread+=":red_circle: Postgres Server(s) in unready state! \\n$(IFS=$'\n'; echo "${resourcesInUnreadyState[*]}")\\n\\n"
fi

if [ "${#criticalCapacityResources[@]}" -gt 0 ]; then
    slackThread+=":red_circle: Postgres Server(s) running above 95% storage capacity!: \\n$(IFS=$'\n'; echo "${criticalCapacityResources[*]}")\\n\\n"

fi

if [ "${#highCapacityResources[@]}" -gt 0 ]; then
    slackThread+=":yellow_circle: Postgres Server(s) running above 80% storage capacity!: \\n$(IFS=$'\n'; echo "${highCapacityResources[*]}")\\n\\n"
fi

echo $slackThread >> postgres-status.txt
