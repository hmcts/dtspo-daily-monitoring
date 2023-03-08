set -ex

ADO_TOKEN=$1
ADO_PROJECT=$2
ADO_DEFINITION_ID=$3
HOURS_FOR_AMBER=$4
HOURS_FOR_RED=$5


MIN_TIME_RED=$(date -d "-${HOURS_FOR_RED} Hours" +"%Y-%m-%dT%H:%M:%SZ" )
RESULT=$(curl -u :$ADO_TOKEN "https://dev.azure.com/hmcts/$ADO_PROJECT/_apis/build/builds?api-version=7.0&definitions=$ADO_DEFINITION_ID&resultFilter=succeeded&\$top=1&minTime=$MIN_TIME_RED")
COUNT=$(jq -r .count <<< "${RESULT}")

if [ "$COUNT" != 1 ]; then
  echo ":red: Pipeline didn't have a successful run in last $HOURS_FOR_RED hours." >> slack-message.txt
  exit 0
fi

MIN_TIME_AMBER=$(date -d "-${HOURS_FOR_AMBER} Hours" +"%Y-%m-%dT%H:%M:%SZ" )
RESULT=$(curl -u :$ADO_TOKEN "https://dev.azure.com/hmcts/$ADO_PROJECT/_apis/build/builds?api-version=7.0&definitions=$ADO_DEFINITION_ID&resultFilter=succeeded&\$top=1&minTime=$MIN_TIME_AMBER")
COUNT=$(jq -r .count <<< "${RESULT}")

if [ "$COUNT" != 1 ]; then
  echo ":amber: Pipeline didn't have a successful run in last $HOURS_FOR_AMBER hours." >> slack-message.txt
  exit 0
fi

echo ":green: Pipeline had a successful run in last $HOURS_FOR_AMBER hours." >> slack-message.txt

