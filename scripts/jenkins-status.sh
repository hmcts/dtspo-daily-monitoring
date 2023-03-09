JENKINS_USERNAME=$1
JENKINS_API_TOKEN=$2
JENKINS_URL=$3

printf "\n:jenkins: <https://build.platform.hmcts.net/|_*Jenkins Status*_> \n\n" >> slack-message.txt

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

