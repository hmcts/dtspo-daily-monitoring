set -e

SUBSCRIPTION=$1

POSTGRES_FLEXIBLE_INSTANCES=$(az postgres flexible-server list --subscription $SUBSCRIPTION --query "[].{id: id, name: name, state: state}")

printf "\n\n:database: PostgreSQL Flexible Server Storage Usage: $SUBSCRIPTION \n\n" >>slack-message.txt

COUNT=$(echo $POSTGRES_FLEXIBLE_INSTANCES | jq '. | length')
STORAGE_SAFE_COUNT=0

for ((INDEX = 0; INDEX < $COUNT; INDEX++)); do
  INSTANCE_ID=$(echo $POSTGRES_FLEXIBLE_INSTANCES | jq -r '.['$INDEX'].id')
  INSTANCE_NAME=$(echo $POSTGRES_FLEXIBLE_INSTANCES | jq -r '.['$INDEX'].name')
  INSTANCE_STATE=$(echo $POSTGRES_FLEXIBLE_INSTANCES | jq -r '.['$INDEX'].state')
  if [ "$INSTANCE_STATE" == "Ready" ]; then
    INSTANCE_URL="https://portal.azure.com/#@HMCTS.NET/resource$INSTANCE_ID"
    STORAGE_USED=$(az monitor metrics list --resource "$INSTANCE_ID" --metric storage_percent --offset 0d6h --interval 6h | jq -r ".value[0].timeseries[0].data[0].average | round")
    if [ "$STORAGE_USED" -gt 95 ]; then
      echo "> :red_circle: <$INSTANCE_URL|_*$INSTANCE_NAME*_> is running above 95% storage capacity at *$STORAGE_USED%*" >>slack-message.txt
    elif [ "$STORAGE_USED" -gt 80 ]; then
      echo "> :yellow_circle: <$INSTANCE_URL|_*$INSTANCE_NAME*_> is running above 80% storage capacity at *$STORAGE_USED%*" >>slack-message.txt
    else
      STORAGE_SAFE_COUNT=$(($STORAGE_SAFE_COUNT+1))
    fi
  else
    echo "> :red_circle: _*$INSTANCE_NAME*_ is in *$INSTANCE_STATE* state." >>slack-message.txt
  fi
done

echo "> :green_circle: $STORAGE_SAFE_COUNT PostgreSQL Flexible Servers are running below 80% storage capacity." >>slack-message.txt
