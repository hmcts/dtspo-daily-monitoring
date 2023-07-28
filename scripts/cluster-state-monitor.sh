#!/bin/bash
#Vars
printf "\n:aks: *Cluster State Check*" >> slack-message.txt

SUBSCRIPTIONS=$(az account list -o json)
while read subscription; do
    SUBSCRIPTION_ID=$(jq -r '.id' <<< $subscription)
    az account set -s $SUBSCRIPTION_ID
    #CLUSTERS=$(az resource list --resource-type Microsoft.ContainerService/managedClusters --query "[?tags.application == 'core']" -o json)
    CLUSTERS=$(az resource list --resource-type Microsoft.ContainerService/managedClusters -o json)

while read cluster; do
    RESOURCE_GROUP=$(jq -r '.resourceGroup' <<< $cluster)
    cluster_name=$(jq -r '.name' <<< $cluster)

    cluster_data=$(az aks show -n $cluster_name -g $RESOURCE_GROUP -o json)
    cluster_status=$(jq -r '.provisioningState' <<< "$cluster_data")
    cluster_id=$(jq -r '.id' <<< "$cluster_data")

    if [[ $cluster_status == "Failed" ]]; then
        printf "\n>:red_circle:  <https://portal.azure.com/#@HMCTS.NET/resource$cluster_id|_*$cluster_name*_> has a provisioning state of $cluster_status" >> slack-message.txt
        failures_exist="true"
    fi
done < <(jq -c '.[]' <<< $CLUSTERS) # end_of_cluster_loop

done < <(jq -c '.[]' <<< $SUBSCRIPTIONS)

if [[ $failures_exist != "true" ]]; then
    printf "\n>:green_circle:  All clusters have a provisioning state of: Succeeded" >> slack-message.txt
fi

