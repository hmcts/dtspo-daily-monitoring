set -ex

ADO_TOKEN=$1
ADO_PROJECT=$2
ADO_DEFINITION_ID=$3
HOURS_FOR_AMBER=$4
HOURS_FOR_RED=$5
PIPELINE_NAME=$6


PIPELINE_MESSAGE="<https://dev.azure.com/hmcts/$ADO_PROJECT/_build?definitionId=$ADO_DEFINITION_ID|$PIPELINE_NAME pipeline>"

#MIN_TIME_RED=$(date -v "-${HOURS_FOR_RED}H" +"%Y-%m-%dT%H:%M:%SZ" )
MIN_TIME_RED=$(date -v "-${HOURS_FOR_RED}H" +"%Y-%m-%dT%H:%M:%SZ" )
RESULT=$(curl -u :$ADO_TOKEN "https://dev.azure.com/hmcts/$ADO_PROJECT/_apis/build/builds?api-version=7.0&definitions=$ADO_DEFINITION_ID&resultFilter=succeeded&\$top=1&minTime=$MIN_TIME_RED")
COUNT=$(jq -r .count <<< "${RESULT}")

if [ "$COUNT" != 1 ]; then
  echo ":red: $PIPELINE_MESSAGE didn't have a successful run in last $HOURS_FOR_RED hours." >> slack-message.txt
  exit 0
fi

#MIN_TIME_AMBER=$(date -v "-${HOURS_FOR_AMBER}H" +"%Y-%m-%dT%H:%M:%SZ" )
MIN_TIME_AMBER=$(date -d "-${HOURS_FOR_AMBER} Hours" +"%Y-%m-%dT%H:%M:%SZ" )
RESULT=$(curl -u :$ADO_TOKEN "https://dev.azure.com/hmcts/$ADO_PROJECT/_apis/build/builds?api-version=7.0&definitions=$ADO_DEFINITION_ID&resultFilter=succeeded&\$top=1&minTime=$MIN_TIME_AMBER")
COUNT=$(jq -r .count <<< "${RESULT}")

if [ "$COUNT" != 1 ]; then
  echo ":amber: $PIPELINE_MESSAGE didn't have a successful run in last $HOURS_FOR_AMBER hours." >> slack-message.txt
  exit 0
fi

echo ":green: $PIPELINE_MESSAGE had a successful run in last $HOURS_FOR_AMBER hours." >> slack-message.txt

