set -ex

REOURCE_GROUP=cft-preview-00-rg
CLUSTER_NAME=cft-preview-00-aks

MAX_COUNT=$( az aks nodepool show --resource-group $REOURCE_GROUP --cluster-name $CLUSTER_NAME --name linux --query maxCount )    
NODE_COUNT=$( az aks nodepool show --resource-group $REOURCE_GROUP --cluster-name $CLUSTER_NAME --name linux --query count )
PERCENTAGE=$((100*$NODE_COUNT/$MAX_COUNT))


if [ $PERCENTAGE -gt 95 ]; then
    echo "> :red_circle: $CLUSTER_NAME is running above 95% capacity at $PERCENTAGE%" >> slack-message.txt
    exit 0
fi

if [ $PERCENTAGE -gt 80 -lt 95 ]; then
    echo "> :yellow_circle: $CLUSTER_NAME is running above 80% capacity at $PERCENTAGE%" >> slack-message.txt
    else echo "> :green_circle: $CLUSTER_NAME is below 80% capacity at $PERCENTAGE%" >> slack-message.txt
    exit 0
fi