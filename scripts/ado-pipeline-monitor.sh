set -ex

ADO_TOKEN=$1
ADO_PROJECT=$2
ADO_DEFINITION_ID=$3
TIME_FOR_AMBER=$4
TIME_FOR_RED=$5
PIPELINE_NAME=$6
BRANCH_NAME=$7


PIPELINE_MESSAGE="<https://dev.azure.com/hmcts/$ADO_PROJECT/_build?definitionId=$ADO_DEFINITION_ID|$PIPELINE_NAME pipeline>"

#MIN_TIME_RED=$(date -v "-${TIME_FOR_RED}" +"%Y-%m-%dT%H:%M:%SZ" )
MIN_TIME_RED=$(date -d "-${TIME_FOR_RED}" +"%Y-%m-%dT%H:%M:%SZ" )
RESULT=$(curl -u :$ADO_TOKEN "https://dev.azure.com/hmcts/$ADO_PROJECT/_apis/build/builds?api-version=7.0&definitions=$ADO_DEFINITION_ID&branchName=$BRANCH_NAME&resultFilter=succeeded&\$top=1&minTime=$MIN_TIME_RED")
COUNT=$(jq -r .count <<< "${RESULT}")

if [ "$COUNT" != 1 ]; then
  echo "> :red_circle: $PIPELINE_MESSAGE didn't have a successful run in last *$TIME_FOR_RED*." >> slack-message.txt
  exit 0
fi

#MIN_TIME_AMBER=$(date -v "-${TIME_FOR_AMBER}" +"%Y-%m-%dT%H:%M:%SZ" )
MIN_TIME_AMBER=$(date -d "-${TIME_FOR_AMBER}" +"%Y-%m-%dT%H:%M:%SZ" )
RESULT=$(curl -u :$ADO_TOKEN "https://dev.azure.com/hmcts/$ADO_PROJECT/_apis/build/builds?api-version=7.0&definitions=$ADO_DEFINITION_ID&resultFilter=succeeded&\$top=1&minTime=$MIN_TIME_AMBER")
COUNT=$(jq -r .count <<< "${RESULT}")

if [ "$COUNT" != 1 ]; then
  echo "> :yellow_circle: $PIPELINE_MESSAGE didn't have a successful run in last *$TIME_FOR_AMBER*." >> slack-message.txt
  exit 0
fi

echo "> :green_circle: $PIPELINE_MESSAGE had a successful run in last *$TIME_FOR_AMBER*." >> slack-message.txt

