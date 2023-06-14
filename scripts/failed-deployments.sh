#!/bin/bash
set -e

SUBSCRIPTION="${1}"
RESOURCEGROUP="${2}"
CLUSTER_NAME="${3}"
SLACKCHANNEL="${4}"
WEBHOOK_URL="${5}"

echo "Get AKS credentials"

az account set --subscription ${SUBSCRIPTION}
az aks get-credentials \
    --resource-group ${RESOURCEGROUP} \
    --name ${CLUSTER_NAME} \
    --admin \
    --overwrite-existing

output_file="failed-deployments.txt"

# Remove the file if it exists
if [[ -f "$output_file" ]]; then
    rm "$output_file"
fi

# Create a new file
touch "$output_file"

# Get the list of all namespaces
namespaces=$(kubectl get namespaces --no-headers=true | awk '{print $1}')

# Flag to track if there are failed deployments
has_failed_deployments=false

# Loop through each namespace
for namespace in $namespaces; do
    echo "Checking deployments in namespace: $namespace"

    # Get the list of deployments in the namespace
    deployments=$(kubectl get deployments -n "$namespace" --no-headers=true)

    # Loop through each deployment
    while read -r line; do
        deployment_name=$(echo "$line" | awk '{print $1}')
        ready_replicas=$(echo "$line" | awk '{print $2}' | awk -F'/' '{print $1}')
        desired_replicas=$(echo "$line" | awk '{print $2}' | awk -F'/' '{print $2}')

        # Check if the deployment has failed (ready replicas are less than desired replicas)
        if [[ "$ready_replicas" != "$desired_replicas" ]]; then
            printf ":flux: Deployment \`%s\` in namespace \`%s\` has failed\n" "$deployment_name" "$namespace" >> "$output_file"
            has_failed_deployments=true
        fi
    done <<<"$deployments"

    echo
done

# Send the failed deployment message to Slack if there are any failures
if [[ "$has_failed_deployments" == true ]]; then
    printf "\n *Daily Monitoring for Failed Deployments on ${CLUSTER_NAME^^}*\n" > "$output_file.temp"
    cat "$output_file" >> "$output_file.temp"
    mv "$output_file.temp" "$output_file"
    bash scripts/failed-deployments-slack.sh "$WEBHOOK_URL" "$SLACKCHANNEL" < "$output_file"
fi
