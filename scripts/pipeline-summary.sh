#!/usr/bin/env bash

# This script summarizes the daily monitoring pipeline results and sends a Slack notification if any tasks failed.

### Setup script environment
set -euo pipefail

# Source central functions script
source scripts/common-functions.sh

slackBotToken=
slackChannelName=
buildId=
buildUrl=
jobStatus=

usage(){
>&2 cat << EOF
------------------------------------------------
Script to summarize pipeline status and notify on failures
------------------------------------------------
Usage: $0
    [ -t | --slackBotToken ]
    [ -c | --slackChannelName ]
    [ -b | --buildId ]
    [ -u | --buildUrl ]
    [ -j | --jobStatus ]
    [ -h | --help ]
EOF
exit 1
}

args=$(getopt -a -o t:c:b:u:j:h: --long slackBotToken:,slackChannelName:,buildId:,buildUrl:,jobStatus:,help -- "$@")
if [[ $? -gt 0 ]]; then
    usage
fi

eval set -- ${args}
while :
do
    case $1 in
        -h | --help)              usage                    ; shift   ;;
        -t | --slackBotToken)     slackBotToken=$2         ; shift 2 ;;
        -c | --slackChannelName)  slackChannelName=$2      ; shift 2 ;;
        -b | --buildId)           buildId=$2               ; shift 2 ;;
        -u | --buildUrl)          buildUrl=$2              ; shift 2 ;;
        -j | --jobStatus)         jobStatus=$2             ; shift 2 ;;
        # -- means the end of the arguments; drop this, and break out of the while loop
        --) shift; break ;;
        *) >&2 echo Unsupported option: $1
            usage ;;
    esac
done

if [[ -z "$slackBotToken" || -z "$slackChannelName" || -z "$buildId" || -z "$buildUrl" || -z "$jobStatus" ]]; then
    {
        echo "------------------------"
        echo 'Please supply all of: '
        echo '- Slack token'
        echo '- Slack channel name'
        echo '- Build ID'
        echo '- Build URL'
        echo '- Job Status'
        echo "------------------------"
    } >&2
    exit 1
fi

echo "##[section]Daily Monitoring Pipeline Summary"
echo "Pipeline completed. Analyzing results..."
echo "Job Status: $jobStatus"

# Check if any tasks failed
if [ "$jobStatus" == "SucceededWithIssues" ] || [ "$jobStatus" == "Failed" ]; then
    echo "##[warning]⚠️ Some monitoring tasks failed or completed with issues"

    # Determine status emoji and message
    PIPELINE_STATUS=":x:"
    STATUS_TEXT="FAILED"
    if [ "$jobStatus" == "SucceededWithIssues" ]; then
        PIPELINE_STATUS=":warning:"
        STATUS_TEXT="COMPLETED WITH ISSUES"
    fi

    # Build the message
    # Since we can't easily enumerate failed tasks without API access,
    # we provide a general message directing to the pipeline logs
    MESSAGE_DETAILS="<${buildUrl}|_*Daily Monitoring Pipeline*_> One or more monitoring checks failed but the pipeline continued.\\n\\nPlease review the pipeline logs to see which specific tasks encountered issues: <${buildUrl}|View Pipeline Details>"

    # Send Slack notification only if there are failures
    slackNotification $slackBotToken $slackChannelName ":azure: $PIPELINE_STATUS Pipeline ${STATUS_TEXT}" "$MESSAGE_DETAILS"

    echo "##[warning]Please review the pipeline logs above for tasks marked with warnings or errors"
    echo "##[warning]Pipeline URL: $buildUrl"

    # Mark the job as succeeded with issues so it doesn't fail completely
    echo "##vso[task.complete result=SucceededWithIssues;]Some monitoring checks failed but pipeline continued"

else
    echo "##[section]✅ All monitoring tasks completed successfully"
    echo "No Slack notification needed - all checks passed!"
fi
