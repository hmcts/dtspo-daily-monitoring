#!/usr/bin/env bash

JIRA_USERNAME=$1
JIRA_PASSWORD=$2

PREVIOUS_DAYS="1"
DOW=$(date +%u)
if [ "$DOW" == "1" ]; then
 #Get Friday stats for Monday report
 PREVIOUS_DAYS="3"
fi

OVERALL_OPEN_ISSUES_RESULT=$(curl   -u $JIRA_USERNAME:$JIRA_PASSWORD -X POST -H "Content-Type: application/json" "https://tools.hmcts.net/jira/rest/api/2/search" \
   --data '{"jql":"project = DTSPO AND IssueType in (\"BAU Task\", \"Task\")  and status not in (Done, Withdrawn, Rejected)  AND (Labels IS EMPTY OR Labels NOT IN (DTSPO-YELLOW, DTSPO-RED, DTSPO-BLUE, DTSPO-WHITE, DTSPO-Orange,TechDebt,BAUTeam-Improvement))","startAt":0,"maxResults":200,"fields":["assignee"]},"expand":"names"')

OPEN_ISSUES_RESULT=$(curl   -u $JIRA_USERNAME:$JIRA_PASSWORD -X POST -H "Content-Type: application/json" "https://tools.hmcts.net/jira/rest/api/2/search" \
   --data '{"jql":"project = DTSPO AND IssueType in (\"BAU Task\")  and status not in (Done, Withdrawn, Rejected)  AND (Labels IS EMPTY OR Labels NOT IN (DTSPO-YELLOW, DTSPO-RED, DTSPO-BLUE, DTSPO-WHITE, DTSPO-Orange,TechDebt,BAUTeam-Improvement))","startAt":0,"maxResults":200,"fields":["assignee"]},"expand":"names"')

OPEN_ISSUES_COUNT=$(jq -r .total <<< "${OPEN_ISSUES_RESULT}")
UNASSIGNED_ISSUES_COUNT=$(jq -r '[.issues[] | select(.fields.assignee==null)] | length'<<< "${OPEN_ISSUES_RESULT}")

ASSIGNED_ISSUES_RESULT=$(jq -r '[.issues[] | select(.fields.assignee!=null)]| [group_by (.fields.assignee.displayName)[] | {user: .[0].fields.assignee.displayName, count: length}] | sort_by(.count) | reverse[]| [ ">_"+.user+"_", .count|tostring ] | join(": ")' <<< "${OVERALL_OPEN_ISSUES_RESULT}")


CLOSED_ISSUES_RESULT=$(curl   -u $JIRA_USERNAME:$JIRA_PASSWORD -X POST -H "Content-Type: application/json" "https://tools.hmcts.net/jira/rest/api/2/search" \
   --data '{"jql":"project = DTSPO AND IssueType in (\"BAU Task\", \"Task\") AND (Labels IS EMPTY OR Labels NOT IN (DTSPO-YELLOW, DTSPO-RED, DTSPO-BLUE, DTSPO-WHITE, DTSPO-Orange,TechDebt,BAUTeam-Improvement)) AND status changed to (Done, Withdrawn, Rejected) ON -'${PREVIOUS_DAYS}'d","startAt":0,"maxResults":200,"fields":["assignee"]},"expand":"names"')

CLOSED_ISSUES_COUNT=$(jq -r .total <<< "${CLOSED_ISSUES_RESULT}")
CLOSED_ISSUES_USER=$(jq -r '[.issues[] | select(.fields.assignee!=null)]| [group_by (.fields.assignee.displayName)[] | {user: .[0].fields.assignee.displayName, count: length}] | sort_by(.count) | reverse[]| [ ">_"+.user+"_", .count|tostring ] | join(": ")' <<< "${CLOSED_ISSUES_RESULT}")

OPEN_PATCHING_ISSUES_RESULT=$(curl   -u $JIRA_USERNAME:$JIRA_PASSWORD -X POST -H "Content-Type: application/json" "https://tools.hmcts.net/jira/rest/api/2/search" \
   --data '{"jql":"project = DTSPO AND IssueType in (\"Task\")  and status not in (Done, Withdrawn, Rejected)  AND (Labels IN (Patching) AND Labels NOT IN (TechDebt,BAUTeam-Improvement))","startAt":0,"maxResults":200,"fields":["assignee"]},"expand":"names"')

OPEN_PATCHING_ISSUES_COUNT=$(jq -r .total <<< "${OPEN_PATCHING_ISSUES_RESULT}")

OPEN_OAT_ISSUES_RESULT=$(curl   -u $JIRA_USERNAME:$JIRA_PASSWORD -X POST -H "Content-Type: application/json" "https://tools.hmcts.net/jira/rest/api/2/search" \
   --data '{"jql":"project = DTSPO AND IssueType in (\"BAU Task\", \"Task\")  and status not in (Done, Withdrawn, Rejected)  AND (Labels IN (OAT) AND Labels NOT IN (DTSPO-YELLOW, DTSPO-RED, DTSPO-BLUE, DTSPO-WHITE, DTSPO-Orange,TechDebt,BAUTeam-Improvement))","startAt":0,"maxResults":200,"fields":["assignee"]},"expand":"names"')

OPEN_OAT_ISSUES_COUNT=$(jq -r .total <<< "${OPEN_OAT_ISSUES_RESULT}")

UNASSIGNED_STATUS=":red_circle:"
if (( "$UNASSIGNED_ISSUES_COUNT" <= 10 )); then
  UNASSIGNED_STATUS=":green_circle:"
elif ((  "$UNASSIGNED_ISSUES_COUNT" <= 15 )); then
  UNASSIGNED_STATUS=":yellow_circle:"
fi

OPEN_ISSUES_STATUS=":red_circle:"
if (( "$OPEN_ISSUES_COUNT" <= 50 )); then
  OPEN_ISSUES_STATUS=":green_circle:"
elif (( "$OPEN_ISSUES_COUNT" <= 70 )); then
  OPEN_ISSUES_STATUS=":yellow_circle:"
fi

printf "\n:jira: <https://bit.ly/3mzE5DL|_*BAU Tickets Status*_> \n\n" >> slack-message.txt

printf "> %s *%s* Open BAU issues\n" "$OPEN_ISSUES_STATUS" "$OPEN_ISSUES_COUNT" >> slack-message.txt
printf "> %s *%s* unassigned BAU issues\n" "$UNASSIGNED_STATUS" "$UNASSIGNED_ISSUES_COUNT" >> slack-message.txt
printf "> %s *%s* Open Patching issues\n" "$OPEN_ISSUES_STATUS" "$OPEN_PATCHING_ISSUES_COUNT" >> slack-message.txt
printf "> %s *%s* Open OAT issues\n" "$OPEN_ISSUES_STATUS" "$OPEN_OAT_ISSUES_COUNT" >> slack-message.txt

printf ">\n>\n>:tada:  *%s issues closed yesterday:* \n>\n" "$CLOSED_ISSUES_COUNT" >> slack-message.txt
echo "${CLOSED_ISSUES_USER}">> slack-message.txt


printf ">\n>\n>:fire: *Current Assigned tickets:* \n>\n" >> slack-message.txt
echo "${ASSIGNED_ISSUES_RESULT}">> slack-message.txt
