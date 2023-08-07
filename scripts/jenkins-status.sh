set -ex

JENKINS_USERNAME=$1
JENKINS_API_TOKEN=$2
JENKINS_URL=$3

printf "\n:jenkins: <https://build.platform.hmcts.net/|_*Jenkins Status*_> \n\n" >> slack-message.txt

BUILD_QUEUE_RESULT=$( curl -u "$JENKINS_USERNAME":"$JENKINS_API_TOKEN" "$JENKINS_URL/queue/api/json")
BUILD_QUEUE_COUNT=$(jq -r '.items | length' <<< "$BUILD_QUEUE_RESULT")

BUILD_QUEUE_STATUS=":red_circle:"
if (( "$BUILD_QUEUE_COUNT" <= 75 )); then
  BUILD_QUEUE_STATUS=":green_circle:"
elif (( "$BUILD_QUEUE_COUNT" <= 125 )); then
  BUILD_QUEUE_STATUS=":yellow_circle:"
fi

printf ">_%s  Build Queue :_ *%s* :sign-queue: \n" "$BUILD_QUEUE_STATUS" "$BUILD_QUEUE_COUNT" >> slack-message.txt

printf ">\n> _Dashboard Status:_  \n>\n" >> slack-message.txt

DASHBOARD_RESULT=$( curl -u $JENKINS_USERNAME:$JENKINS_API_TOKEN "$JENKINS_URL/view/Platform/api/json?depth=1")

count=$(jq -r '.jobs | length' <<< $DASHBOARD_RESULT)

for ((i=0; i< ${count}; i++)); do
    URL=$(jq -r '.jobs['$i'].url' <<< "$DASHBOARD_RESULT")
    COLOR=$(jq -r '.jobs['$i'].color' <<< "$DASHBOARD_RESULT")
    FULL_DISPLAY_NAME=$(jq -r '.jobs['$i'].fullDisplayName' <<< "$DASHBOARD_RESULT" | sed -e "s/»/:/g")

    BUILD_STATUS=":yellow_circle:"
    if [[ "$COLOR" == "red" ]]; then
    BUILD_STATUS=":red_circle:"
    elif [[ "$COLOR" == "blue" ]]; then
    BUILD_STATUS=":green_circle:"
    fi
  printf "> %s <%s|%s> \n" "$BUILD_STATUS" "$URL" "$FULL_DISPLAY_NAME" >> slack-message.txt
done

