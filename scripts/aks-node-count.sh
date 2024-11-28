#!/usr/bin/env bash

### Setup script environment
set -e

# Source central functions script
source scripts/common-functions.sh

resourceGroup=
aksClusterName=

usage(){
>&2 cat << EOF
    ------------------------------------------------
    Script to check GitHub page expiry
    ------------------------------------------------
    Usage: $0
        [ -r | --resourceGroup ]
        [ -a | --aksClusterName ]
        [ -h | --help ]
EOF
exit 1
}

args=$(getopt -a -o r:a:h: --long resourceGroup:,aksClusterName:,help -- "$@")
if [[ $? -gt 0 ]]; then
    usage
fi

eval set -- ${args}
while :
do
    case $1 in
        -h | --help)           usage             ; shift   ;;
        -r | --resourceGroup)  resourceGroup=$2  ; shift 2 ;;
        -a | --aksClusterName) aksClusterName=$2 ; shift 2 ;;
        -d | --checkDays)      checkDays=$2      ; shift 2 ;;
        # -- means the end of the arguments; drop this, and break out of the while loop
        --) shift; break ;;
        *) >&2 echo Unsupported option: $1
            usage ;;
    esac
done

if [[ -z "$resourceGroup" || -z "$aksClusterName" ]]; then
    {
        echo "------------------------"
        echo 'Please supply all of: '
        echo '- Resource Group name'
        echo '- AKS Cluster name'
        echo "------------------------"
    } >&2
    exit 1
fi

# Setup variables
slackThread=""

rgExists=$( az group exists --name $resourceGroup )

if [[ $rgExists == false ]]; then
    echo "$resourceGroup does not exist"
    exit 0
fi

clusterCount=$(az aks list --resource-group $resourceGroup --output json | jq -r '. | length')

if [[ $clusterCount == 0 ]]; then
    echo "$aksClusterName does not exist"
    exit 0
fi

maxCount=$( az aks nodepool show --resource-group $resourceGroup --cluster-name $aksClusterName --name linux --query maxCount )
nodeCount=$( az aks nodepool show --resource-group $resourceGroup --cluster-name $aksClusterName --name linux --query count )
percentageCalculation=$((100*$nodeCount/$maxCount))

clusterURL="https://portal.azure.com/#@HMCTS.NET/resource/subscriptions/8b6ea922-0862-443e-af15-6056e1c9b9a4/resourceGroups/$resourceGroup/providers/Microsoft.ContainerService/managedClusters/$aksClusterName/overview"

if [ $percentageCalculation -gt 95 ]; then
    slackThread+=":red_circle: <$CLUSTER_URL|_*Cluster: $aksClusterName*_> is running above 95% capacity at *$percentageCalculation%*"
elif [ $percentageCalculation -gt 80 ]; then
    slackThread+=":yellow_circle: <$CLUSTER_URL|_*Cluster: $aksClusterName*_> is running above 80% capacity at *$percentageCalculation%*"
else
    slackThread+=":green_circle: <$CLUSTER_URL|_*Cluster: $aksClusterName*_> is running below 80% capacity at *$percentageCalculation%*"
fi
