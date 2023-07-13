#!/usr/bin/env bash
set -ex
SNOW_USERNAME=$1
SNOW_PASSWORD=$2

OPEN_INCIDENTS_RESULT=$( curl -u "$SNOW_USERNAME":"$SNOW_PASSWORD" "https://mojcppprod.service-now.com/api/now/stats/incident?sysparm_count=true&sysparm_fields=number,state&sysparm_query=assignment_group=6e1f4d64db642b8046cc72dabf96195f^ORassignment_group=96636bdcdb6d334046cc72dabf961978^state!=6^state!=7")
OPEN_INCIDENTS_COUNT=$(jq -r .result.stats.count <<< "${OPEN_INCIDENTS_RESULT}")


OPEN_PROBLEMS_RESULT=$( curl -u "$SNOW_USERNAME":"$SNOW_PASSWORD" "https://mojcppprod.service-now.com/api/now/stats/problem?sysparm_count=true&sysparm_fields=number,state&sysparm_query=assignment_group=6e1f4d64db642b8046cc72dabf96195f^ORassignment_group=96636bdcdb6d334046cc72dabf961978^state!=9^state!=4^state!=11")
OPEN_PROBLEMS_COUNT=$(jq -r .result.stats.count <<< "${OPEN_PROBLEMS_RESULT}")


OPEN_INCIDENTS_STATUS=":red_circle:"
if (( "$OPEN_INCIDENTS_COUNT" <= 10 )); then
  OPEN_INCIDENTS_STATUS=":green_circle:"
elif ((  "$OPEN_INCIDENTS_COUNT" <= 15 )); then
  OPEN_INCIDENTS_STATUS=":yellow_circle:"
fi

OPEN_PROBLEMS_STATUS=":red_circle:"
if (( "$OPEN_PROBLEMS_COUNT" <= 10 )); then
  OPEN_PROBLEMS_STATUS=":green_circle:"
elif ((  "$OPEN_PROBLEMS_COUNT" <= 15 )); then
  OPEN_PROBLEMS_STATUS=":yellow_circle:"
fi

printf "\n:service-now: <https://mojcppprod.service-now.com/|_*ServiceNow Status*_> \n\n" >> slackmessage.txt

printf "> %s *%s* Open incidents\n" "$OPEN_INCIDENTS_STATUS" "$OPEN_INCIDENTS_COUNT" >> slackmessage.txt
printf "> %s *%s* Open problems\n" "$OPEN_PROBLEMS_STATUS" "$OPEN_PROBLEMS_COUNT" >> slackmessage.txt