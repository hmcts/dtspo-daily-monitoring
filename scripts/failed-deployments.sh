#!/bin/bash
set -e

SUBSCRIPTION="${1}"
RESOURCEGROUP="${2}"
CLUSTER_NAME="${3}"
SLACKCHANNEL="${4}"
WEBHOOK_URL="${5}"

echo  "Get aks credentials "

az account set --subscription ${SUBSCRIPTION}
az aks get-credentials \
    --resource-group ${RESOURCEGROUP} \
    --name ${CLUSTER_NAME} \
    --admin \
    --overwrite-existing

# Get the list of all namespaces
namespaces=$(kubectl get namespaces --no-headers=true | awk '{print $1}')

# Loop through each namespace
for namespace in $namespaces
do
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
      printf "Deployment \`%s\` in namespace \`%s\` on *%s* has failed\n" "$deployment_name" "$namespace" "$CLUSTER_NAME" >> failed-deployments.txt

      bash scripts/failed-deployments-slack.sh "$WEBHOOK_URL" "$SLACKCHANNEL"
    fi
  done <<< "$deployments"

  echo
done
