set -e

SUBSCRIPTION=$1

POSTGRES_FLEXIBLE_INSTANCES=$(az postgres flexible-server list --subscription $SUBSCRIPTION --query "[].{id: id, name: name}")

printf "\n\n:database: PostgreSQL Flexible Server Storage Usage: $SUBSCRIPTION \n\n" >>slack-message.txt

COUNT=$(echo $POSTGRES_FLEXIBLE_INSTANCES | jq '. | length')
STORAGE_SAFE_COUNT=0

for ((INDEX = 0; INDEX < $COUNT; INDEX++)); do
  INSTANCE_ID=$(echo $POSTGRES_FLEXIBLE_INSTANCES | jq -r '.['$INDEX'].id')
  INSTANCE_NAME=$(echo $POSTGRES_FLEXIBLE_INSTANCES | jq -r '.['$INDEX'].name')
  INSTANCE_URL="https://portal.azure.com/#@HMCTS.NET/resource$INSTANCE_ID"
  STORAGE_USED=$(az monitor metrics list --resource "$INSTANCE_ID" --metric storage_percent --offset 0d6h --interval 6h | jq -r ".value[0].timeseries[0].data[0].average | round")
  echo "Storaged used: $STORAGE_USED"
  if [ "$STORAGE_USED" -gt 60 ]; then
    echo "> :red_circle: <$INSTANCE_URL|_*$INSTANCE_NAME*_> is running above 60% storage capacity at *$STORAGE_USED%*" >>slack-message.txt
  elif [ "$STORAGE_USED" -gt 30 ]; then
    echo "> :yellow_circle: <$INSTANCE_URL|_*$INSTANCE_NAME*_> is running above 30% storage capacity at *$STORAGE_USED%*" >>slack-message.txt
  else
    STORAGE_SAFE_COUNT=$(($STORAGE_SAFE_COUNT+1))
  fi
done

echo "> :green_circle: $STORAGE_SAFE_COUNT PostgreSQL Flexible Servers are running below 30% storage capacity." >>slack-message.txt
