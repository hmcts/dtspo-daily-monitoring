#!/usr/bin/env bash

### Setup script environment
set -euox pipefail

# Source central functions script
source scripts/common-functions.sh

slackBotToken=
slackChannelName=
jiraUsername=
jiraPassword=

usage(){
>&2 cat << EOF
------------------------------------------------
Script to check GitHub page expiry
------------------------------------------------
Usage: $0
    [ -t | --slackBotToken ]
    [ -c | --slackChannelName ]
    [ -u | --jiraUsername ]
    [ -p | --jiraPassword ]
    [ -h | --help ]
EOF
exit 1
}

args=$(getopt -a -o t:c:p:g: --long slackBotToken:,slackChannelName:,jiraUsername:,jiraPassword:,help -- "$@")
if [[ $? -gt 0 ]]; then
    usage
fi

eval set -- ${args}
while :
do
    case $1 in
        -h | --help)              usage                 ; shift   ;;
        -t | --slackBotToken)     slackBotToken=$2      ; shift 2 ;;
        -c | --slackChannelName)  slackChannelName=$2   ; shift 2 ;;
        -u | --jiraUsername)      jiraUsername=$2       ; shift 2 ;;
        -p | --jiraPassword)      jiraPassword=$2       ; shift 2 ;;
        # -- means the end of the arguments; drop this, and break out of the while loop
        --) shift; break ;;
        *) >&2 echo Unsupported option: $1
            usage ;;
    esac
done

if [ -z "$slackBotToken" ] || [ -z "$slackChannelName" ] || [ -z "$jiraUsername" ] || [ -z "$jiraPassword" ]; then
        echo "------------------------"
        echo 'Please supply all of Slack token, Slack channel name, Jira username and Jira password' >&2
        echo "------------------------"
        exit 1
fi

PREVIOUS_DAYS="1"
DOW=$(date +%u)
if [ "$DOW" == "1" ]; then
  #Get Friday stats for Monday report
  PREVIOUS_DAYS="3"
fi

OVERALL_OPEN_ISSUES_RESULT=$(curl   -u $jiraUsername:$jiraPassword -X POST -H "Content-Type: application/json" "https://tools.hmcts.net/jira/rest/api/2/search" \
  --data '{"jql":"project = DTSPO AND IssueType in (\"Support\", \"Task\")  and status not in (Done, Withdrawn, Rejected)  AND (Labels IS EMPTY OR Labels NOT IN (DTSPO-YELLOW, DTSPO-RED, DTSPO-BLUE, DTSPO-WHITE, DTSPO-Orange,TechDebt,BAUTeam-Improvement))","startAt":0,"maxResults":200,"fields":["assignee"]},"expand":"names"')

OPEN_ISSUES_RESULT=$(curl   -u $jiraUsername:$jiraPassword -X POST -H "Content-Type: application/json" "https://tools.hmcts.net/jira/rest/api/2/search" \
  --data '{"jql":"project = DTSPO AND IssueType in (\"Support\")  and status not in (Done, Withdrawn, Rejected)  AND (Labels IS EMPTY OR Labels NOT IN (DTSPO-YELLOW, DTSPO-RED, DTSPO-BLUE, DTSPO-WHITE, DTSPO-Orange,TechDebt,BAUTeam-Improvement))","startAt":0,"maxResults":200,"fields":["assignee"]},"expand":"names"')

OPEN_ISSUES_COUNT=$(jq -r .total <<< "${OPEN_ISSUES_RESULT}")
UNASSIGNED_ISSUES_COUNT=$(jq -r '[.issues[] | select(.fields.assignee==null)] | length'<<< "${OPEN_ISSUES_RESULT}")

ASSIGNED_ISSUES_RESULT=$(jq -r '[.issues[] | select(.fields.assignee!=null)]| [group_by (.fields.assignee.displayName)[] | {user: .[0].fields.assignee.displayName, count: length}] | sort_by(.count) | reverse[]| [ ">_"+.user+"_", .count|tostring ] | join(": ")' <<< "${OVERALL_OPEN_ISSUES_RESULT}")

CLOSED_ISSUES_RESULT=$(curl   -u $jiraUsername:$jiraPassword -X POST -H "Content-Type: application/json" "https://tools.hmcts.net/jira/rest/api/2/search" \
  --data '{"jql":"project = DTSPO AND IssueType in (\"Support\", \"Task\") AND (Labels IS EMPTY OR Labels NOT IN (DTSPO-YELLOW, DTSPO-RED, DTSPO-BLUE, DTSPO-WHITE, DTSPO-Orange,TechDebt,BAUTeam-Improvement)) AND status changed to (Done, Withdrawn, Rejected) ON -'${PREVIOUS_DAYS}'d","startAt":0,"maxResults":200,"fields":["assignee"]},"expand":"names"')

CLOSED_ISSUES_COUNT=$(jq -r .total <<< "${CLOSED_ISSUES_RESULT}")
CLOSED_ISSUES_USER=$(jq -r '[.issues[] | select(.fields.assignee!=null)]| [group_by (.fields.assignee.displayName)[] | {user: .[0].fields.assignee.displayName, count: length}] | sort_by(.count) | reverse[]| [ ">_"+.user+"_", .count|tostring ] | join(": ")' <<< "${CLOSED_ISSUES_RESULT}")

OPEN_PATCHING_ISSUES_RESULT=$(curl   -u $jiraUsername:$jiraPassword -X POST -H "Content-Type: application/json" "https://tools.hmcts.net/jira/rest/api/2/search" \
  --data '{"jql":"project = DTSPO AND IssueType in (\"Task\")  and status not in (Done, Withdrawn, Rejected)  AND (Labels IN (Patching) AND Labels NOT IN (TechDebt,BAUTeam-Improvement))","startAt":0,"maxResults":200,"fields":["assignee"]},"expand":"names"')

OPEN_PATCHING_ISSUES_COUNT=$(jq -r .total <<< "${OPEN_PATCHING_ISSUES_RESULT}")

OPEN_OAT_ISSUES_RESULT=$(curl   -u $jiraUsername:$jiraPassword -X POST -H "Content-Type: application/json" "https://tools.hmcts.net/jira/rest/api/2/search" \
  --data '{"jql":"project = DTSPO AND IssueType in (\"Support\", \"Task\")  and status not in (Done, Withdrawn, Rejected)  AND (Labels IN (OAT) AND Labels NOT IN (DTSPO-YELLOW, DTSPO-RED, DTSPO-BLUE, DTSPO-WHITE, DTSPO-Orange,TechDebt,BAUTeam-Improvement))","startAt":0,"maxResults":200,"fields":["assignee"]},"expand":"names"')

OPEN_OAT_ISSUES_COUNT=$(jq -r .total <<< "${OPEN_OAT_ISSUES_RESULT}")

AUTO_WITHDRAWN_ISSUES_RESULT=$(curl   -u $jiraUsername:$jiraPassword -X POST -H "Content-Type: application/json" "https://tools.hmcts.net/jira/rest/api/2/search" \
  --data '{"jql":"project = DTSPO AND IssueType in (\"Support\") AND Labels in (auto-withdrawn) AND status changed to (Withdrawn) ON -'${PREVIOUS_DAYS}'d","startAt":0,"maxResults":200,"fields":["assignee"]},"expand":"names"')

AUTO_WITHDRAWN_ISSUES_COUNT=$(jq -r .total <<< "${AUTO_WITHDRAWN_ISSUES_RESULT}")

UNASSIGNED_STATUS=":red_circle:"
if (( "$UNASSIGNED_ISSUES_COUNT" <= 10 )); then
  UNASSIGNED_STATUS=":green_circle:"
elif ((  "$UNASSIGNED_ISSUES_COUNT" <= 15 )); then
  UNASSIGNED_STATUS=":yellow_circle:"
fi

OPEN_ISSUES_STATUS=":red_circle:"
if (( "$OPEN_ISSUES_COUNT" <= 70 )); then
  OPEN_ISSUES_STATUS=":green_circle:"
elif (( "$OPEN_ISSUES_COUNT" <= 90 )); then
  OPEN_ISSUES_STATUS=":yellow_circle:"
fi

OPEN_PATCHING_ISSUES_STATUS=":red_circle:"
if (( "$OPEN_PATCHING_ISSUES_COUNT" <= 20 )); then
  OPEN_PATCHING_ISSUES_STATUS=":green_circle:"
elif (( "$OPEN_PATCHING_ISSUES_COUNT" <= 25 )); then
  OPEN_PATCHING_ISSUES_STATUS=":yellow_circle:"
fi

OPEN_OAT_ISSUES_STATUS=":red_circle:"
if (( "$OPEN_OAT_ISSUES_COUNT" <= 15 )); then
  OPEN_OAT_ISSUES_STATUS=":green_circle:"
elif (( "$OPEN_OAT_ISSUES_COUNT" <= 20 )); then
  OPEN_OAT_ISSUES_STATUS=":yellow_circle:"
fi


# If any of the unassigned or open checks return red set the overall status to red, if no reds but any yellow then yellow otherwise leave as green
jiraStatus=":green_circle:"
if [[ "$UNASSIGNED_STATUS" == ":red_circle:" || "$OPEN_ISSUES_STATUS" == ":red_circle:" || "$OPEN_PATCHING_ISSUES_STATUS" == ":red_circle:" || "$OPEN_OAT_ISSUES_STATUS" == ":red_circle:" ]]; then
  jiraStatus=":red_circle:"
elif [[ "$UNASSIGNED_STATUS" == ":yellow_circle:" || "$OPEN_ISSUES_STATUS" == ":yellow_circle:" || "$OPEN_PATCHING_ISSUES_STATUS" == ":yellow_circle:" || "$OPEN_OAT_ISSUES_STATUS" == ":yellow_circle:" ]]; then
  jiraStatus=":yellow_circle:"
fi

# If the number of tickets closed is less than 5 or 10 set the status accordingly otherwise leave as green
ticketStatus=":green_circle:"
if [[ "$CLOSED_ISSUES_COUNT" -lt 5 ]]; then
  ticketStatus=":red_circle:"
elif [[ "$CLOSED_ISSUES_COUNT" -lt 10 ]]; then
  ticketStatus=":yellow_circle:"
fi

openIssues=$(printf "%s *%s* <https://bit.ly/4iPQ6Nr|Open BAU issues>\n" "$OPEN_ISSUES_STATUS" "$OPEN_ISSUES_COUNT")
unassignedIssues=$(printf "%s *%s* <https://bit.ly/4iD9AFk|Unassigned BAU issues>\n" "$UNASSIGNED_STATUS" "$UNASSIGNED_ISSUES_COUNT")
patchingIssues=$(printf "%s *%s* <https://bit.ly/4bU9gzj|Open Patching issues>\n" "$OPEN_PATCHING_ISSUES_STATUS" "$OPEN_PATCHING_ISSUES_COUNT")
oatIssues=$(printf "%s *%s* <https://bit.ly/4bUIEyf|Open OAT issues>\n" "$OPEN_OAT_ISSUES_STATUS" "$OPEN_OAT_ISSUES_COUNT")

if [ "$AUTO_WITHDRAWN_ISSUES_COUNT" != "0" ]; then
  withdrawnIssues=$(printf ":hourglass_flowing_sand: *%s issues automatically withdrawn yesterday:* <https://tools.hmcts.net/jira/issues/?jql=project%%20%%3D%%20DTSPO%%20AND%%20IssueType%%20in%%20(%%22Support%%22)%%20AND%%20Labels%%20in%%20(auto-withdrawn)%%20AND%%20status%%20changed%%20to%%20(Withdrawn)%%20ON%%20-${PREVIOUS_DAYS}d|_*View withdrawn issues*_>" "${AUTO_WITHDRAWN_ISSUES_COUNT}")
else
  withdrawnIssues=":hourglass_flowing_sand: *No issues were automatically withdrawn yesterday*"
fi

if [[ "$jiraStatus" == ":red_circle:" || "$jiraStatus" == ":yellow_circle:" ]]; then
  slackNotification $slackBotToken $slackChannelName "$jiraStatus Jira Status" ":jira: <https://bit.ly/4iPQ6Nr|_*BAU Tickets Status*_>"
  slackThreadResponse $slackBotToken $slackChannelName "${openIssues}\\n${unassignedIssues}\\n${patchingIssues}\\n${oatIssues}\\n${withdrawnIssues}" $TS
fi

if [[ "$ticketStatus" == ":red_circle:" || "$ticketStatus" == ":yellow_circle:" ]]; then

  closedIssues=$(printf ":tada: *%s issues closed yesterday*" "$CLOSED_ISSUES_COUNT")
  slackNotification $slackBotToken $slackChannelName "$ticketStatus Jira Ticket Status" "${closedIssues}"

  slackThreadResponse $slackBotToken $slackChannelName "${closedIssues}:" $TS
  slackThreadResponse $slackBotToken $slackChannelName "$CLOSED_ISSUES_USER" $TS

  currentlyAssigned=$(printf ":fire: *Current Assigned tickets:*")
  slackThreadResponse $slackBotToken $slackChannelName "${currentlyAssigned}" $TS
  slackThreadResponse $slackBotToken $slackChannelName "$ASSIGNED_ISSUES_RESULT" $TS

fi
