set -ex

REOURCE_GROUP=cft-preview-00-rg
CLUSTER_NAME=cft-preview-00-aks
    
NODE_COUNT=$( az aks nodepool show --resource-group $REOURCE_GROUP --cluster-name $CLUSTER_NAME --name linux --query count )


if [ $NODE_COUNT -gt 170 ]; then
    echo "> :red_circle: $CLUSTER_NAME is running above 95% capacity" >> slack-message.txt
    exit 0
fi

if [ $NODE_COUNT -gt 140 -lt 170 ]; then
    echo "> :yellow_circle: $CLUSTER_NAME is running above 80% capacity" >> slack-message.txt
    else echo "> :green_circle: $CLUSTER_NAME is below 80% capacity" >> slack-message.txt
    exit 0
fi