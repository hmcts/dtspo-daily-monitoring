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
    Script to check AKS cluster capacity and resource usage
    ------------------------------------------------
    Usage: $0
        [ -r | --resourceGroup ]
        [ -a | --aksClusterName ]
        [ -h | --help ]
EOF
exit 1
}

args=$(getopt -a -o r:a:h:d: --long resourceGroup:,aksClusterName:,help,checkDays: -- "$@")
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

# Function to fetch and format metric
get_metric() {
    local metric_name=$1
    local value=$(az monitor metrics list \
        --resource "$clusterId" \
        --metric "$metric_name" \
        --start-time "$startTime" \
        --end-time "$endTime" \
        --interval PT1M \
        --aggregation Average \
        --query 'value[0].timeseries[0].data[-1].average' \
        -o tsv 2>/dev/null)
    
    if [[ -z "$value" || "$value" == "null" ]]; then
        echo "N/A"
    else
        printf "%.1f" "$value"
    fi
}

# Function to check metric threshold and update status
check_threshold() {
    local value=$1
    local warning_threshold=$2
    local critical_threshold=$3
    
    [[ "$value" == "N/A" ]] && return
    
    local int_value=${value%.*}
    if [ "$int_value" -gt "$critical_threshold" ]; then
        overallStatus=":red_circle:"
        statusText="critical"
    elif [ "$int_value" -gt "$warning_threshold" ] && [ "$overallStatus" != ":red_circle:" ]; then
        overallStatus=":yellow_circle:"
        statusText="warning"
    fi
}

# Setup variables
rgExists=$(az group exists --name $resourceGroup)

if [[ $rgExists == false ]]; then
    echo "$resourceGroup does not exist"
    exit 0
fi

clusterCount=$(az aks list --resource-group $resourceGroup --output json | jq -r '. | length')

if [[ $clusterCount == 0 ]]; then
    echo "$aksClusterName does not exist"
    exit 0
fi

# Get node pool info
maxCount=$(az aks nodepool show --resource-group $resourceGroup --cluster-name $aksClusterName --name linux --query maxCount -o tsv)
nodeCount=$(az aks nodepool show --resource-group $resourceGroup --cluster-name $aksClusterName --name linux --query count -o tsv)
nodeCapacity=$((100*$nodeCount/$maxCount))

# Get cluster resource ID and set time range for metrics
clusterId=$(az aks show --resource-group $resourceGroup --name $aksClusterName --query id -o tsv)
endTime=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
startTime=$(date -u -d '5 minutes ago' +"%Y-%m-%dT%H:%M:%SZ")

# Fetch metrics
cpuUsage=$(get_metric "node_cpu_usage_percentage")
memoryUsage=$(get_metric "node_memory_working_set_percentage")
diskUsage=$(get_metric "node_disk_usage_percentage")

# Determine overall status
overallStatus=":green_circle:"
statusText="healthy"

check_threshold "$nodeCapacity" 80 95
check_threshold "$cpuUsage" 75 90
check_threshold "$memoryUsage" 75 90
check_threshold "$diskUsage" 70 85

# Check for over-provisioning (all resources below 40% usage)
provisioningStatus=":green_circle:"
provisioningText="healthy"

# Only check if all metrics are available (not N/A)
if [[ "$cpuUsage" != "N/A" && "$memoryUsage" != "N/A" && "$diskUsage" != "N/A" ]]; then
    # Convert to integers for comparison
    cpuInt=${cpuUsage%.*}
    memInt=${memoryUsage%.*}
    diskInt=${diskUsage%.*}
    
    # Flag as over-provisioned if ALL are below 40%
    if [ "$cpuInt" -lt 40 ] && [ "$memInt" -lt 40 ] && [ "$diskInt" -lt 40 ]; then
        provisioningStatus=":red_circle:"
        provisioningText="over-provisioned"
        
        # Set overall status to warning if not already critical
        if [ "$overallStatus" == ":green_circle:" ]; then
            overallStatus=":yellow_circle:"
            statusText="warning"
        fi
    fi
fi

# Build Slack message
clusterURL="https://portal.azure.com/#@HMCTS.NET/resource/subscriptions/8b6ea922-0862-443e-af15-6056e1c9b9a4/resourceGroups/$resourceGroup/providers/Microsoft.ContainerService/managedClusters/$aksClusterName/overview"

slackThread="$overallStatus <$clusterURL|*$aksClusterName*> - Status: *$statusText*\n"
slackThread+="  • Node Capacity: *${nodeCapacity}%* (${nodeCount}/${maxCount} nodes)\n"
slackThread+="  • Provisioning Status: $provisioningStatus *$provisioningText*\n"
slackThread+="  • Average Average CPU Usage: *${cpuUsage}%*\n"
slackThread+="  • Average Average Memory Usage: *${memoryUsage}%*\n"
slackThread+="  • Average Average Disk Usage: *${diskUsage}%*"

echo -e "$slackThread" >> aks-cluster-status.txt
