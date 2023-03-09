set -ex

RESOURCE_GROUP=$1
CLUSTER_NAME=$2

RESOURCE_GROUP_EXIST=$( az group exists --name $RESOURCE_GROUP )

if [[ $RESOURCE_GROUP_EXIST == false ]]; then
    echo "$RESOURCE_GROUP does not exist"
    exit 0
fi

CLUSTER_RESULT=$( az aks list --resource-group $RESOURCE_GROUP --output json )

# az aks list --resource-group $RESOURCE_GROUP --output json
CLUSTER_COUNT=$(jq -r '. | length' <<< "${CLUSTER_RESULT}")

if [[ $CLUSTER_COUNT == 0 ]]; then
    echo "$CLUSTER_NAME does not exist"
    exit 0
fi

MAX_COUNT=$( az aks nodepool show --resource-group $RESOURCE_GROUP --cluster-name $CLUSTER_NAME --name linux --query maxCount )    
NODE_COUNT=$( az aks nodepool show --resource-group $RESOURCE_GROUP --cluster-name $CLUSTER_NAME --name linux --query count )
PERCENTAGE=$((100*$NODE_COUNT/$MAX_COUNT))

CLUSTER_URL="https://portal.azure.com/#@HMCTS.NET/resource/subscriptions/8b6ea922-0862-443e-af15-6056e1c9b9a4/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.ContainerService/managedClusters/$CLUSTER_NAME/overview"

printf "\n\n:aks: <$CLUSTER_URL|_*Cluster $CLUSTER_NAME Status*_>  \n\n" >> slack-message.txt
if [ $PERCENTAGE -gt 95 ]; then
    echo "> :red_circle: _*$CLUSTER_NAME*_ is running above 95% capacity at *$PERCENTAGE%*" >> slack-message.txt
elif [ $PERCENTAGE -gt 80 ]; then
    echo "> :yellow_circle: _*$CLUSTER_NAME*_ is running above 80% capacity at *$PERCENTAGE%*" >> slack-message.txt
else 
    echo "> :green_circle: _*$CLUSTER_NAME*_ is below 80% capacity at *$PERCENTAGE%*" >> slack-message.txt
fi