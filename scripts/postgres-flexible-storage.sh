set -ex

SUBSCRIPTION=$1

POSTGRES_FLEXIBLE_INSTANCES=$(az postgres flexible-server list --subscription $SUBSCRIPTION --query "[].{id: id, name: name}")

printf "\n\n:database: PostgreSQL Flexible Server Storage Usage: $SUBSCRIPTION \n\n" >>slack-message.txt

COUNT=$(echo $POSTGRES_FLEXIBLE_INSTANCES | jq '. | length')

for ((INDEX = 0; INDEX < $COUNT; INDEX++)); do
  INSTANCE_ID=$(echo $POSTGRES_FLEXIBLE_INSTANCES | jq -r '.['$INDEX'].id')
  INSTANCE_NAME=$(echo $POSTGRES_FLEXIBLE_INSTANCES | jq -r '.['$INDEX'].name')
  INSTANCE_URL="https://portal.azure.com/#@HMCTS.NET/resource$INSTANCE_ID"
  STORAGE_USED=$(az monitor metrics list --resource "$INSTANCE_ID" --metric storage_percent --offset 0d6h --interval 6h | jq -r ".value[0].timeseries[0].data[0].average")
  if [ $STORAGE_USED -gt 95 ]; then
    echo "> :red_circle: <$INSTANCE_URL|_*$INSTANCE_NAME*_> is running above 95% storage capacity at *$STORAGE_USED%*" >>slack-message.txt
  elif [ $STORAGE_USED -gt 80 ]; then
    echo "> :yellow_circle: <$INSTANCE_URL|_*$INSTANCE_NAME*_> is running above 80% storage capacity at *$STORAGE_USED%*" >>slack-message.txt
  else
    echo "> :green_circle: <$INSTANCE_URL|_*$INSTANCE_NAME*_> is below 80% storage capacity at *$STORAGE_USED%*" >>slack-message.txt
  fi
done
