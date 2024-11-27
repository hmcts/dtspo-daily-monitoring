#!/bin/bash
# This script expects the following options:

### Setup script environment
set -euo pipefail

# Source central functions script
source scripts/common-functions.sh

# Github Api Token
githubToken=
# Repository to check
githubRepo=
# Branch name i.e. Master
branch=
# Workflow run this is optional if its not speified the script will check all runs in workflow
run=
# Github owner
owner=hmcts

usage(){
>&2 cat << EOF
------------------------------------------------
Script to check GitHub page expiry
------------------------------------------------
Usage: $0
    [ -t | --githubToken ]
    [ -g | --githubRepo ]
    [ -b | --branch ]
    [ -r | --run ]
    [ -h | --help ]
EOF
exit 1
}

args=$(getopt -a -o t:g:b:r:h: --long githubToken:,githubRepo:,branch:,run:,help -- "$@")
if [[ $? -gt 0 ]]; then
    usage
fi

eval set -- ${args}
while :
do
    case $1 in
        -h | --help)            usage           ; shift   ;;
        -t | --githubToken)     githubToken=$2  ; shift 2 ;;
        -g | --githubRepo)      githubRepo=$2   ; shift 2 ;;
        -b | --branch)          branch=$2       ; shift 2 ;;
        -r | --run)             run=$2          ; shift 2 ;;
        # -- means the end of the arguments; drop this, and break out of the while loop
        --) shift; break ;;
        *) >&2 echo Unsupported option: $1
            usage ;;
    esac
done

if [[ -z "$githubToken" || -z "$githubRepo" || -z "$branch" ]]; then
    {
        echo "------------------------"
        echo 'Please supply all of: '
        echo '- GitHub Token'
        echo '- GitHub Repo'
        echo '- Branch'
        echo "------------------------"
    } >&2
    exit 1
fi

# Function to fetch workflow runs
fetch_workflow_runs() {
    local workflow_id=$1
    curl -s -L -H "Accept: application/vnd.github+json" -H "Authorization: Bearer ${token}" -H "X-GitHub-Api-Version: 2022-11-28" "https://api.github.com/repos/${owner}/${repo}/actions/workflows/${workflow_id}/runs?per_page=1&branch=${branch}" | jq -r '.workflow_runs[] | {status: .status, conclusion: .conclusion, URL: .html_url, StartTime: .run_started_at}'
}

# Determine if run was a supplied value, if not then process all workflows in the repo
# Output will be JSON formatted Id: Name: key/values.
if [[ -z "${run}" ]]; then
    workflows_response=$(curl -s -L -H "Accept: application/vnd.github+json" -H "Authorization: Bearer ${token}" -H "X-GitHub-Api-Version: 2022-11-28" https://api.github.com/repos/${owner}/${repo}/actions/workflows | jq -r '.workflows[] | {id: .id, name: .name}')
else
    workflows_response=$(curl -s -L -H "Accept: application/vnd.github+json" -H "Authorization: Bearer ${token}" -H "X-GitHub-Api-Version: 2022-11-28" "https://api.github.com/repos/${owner}/${repo}/actions/workflows" | jq -r --arg workflow "$run" '[.workflows[]]| map(select(.name==$workflow)) | {id: .[].id, name: .[].name}')
fi

# Main script logic
echo "WORKFLOW RESPONSE: ${workflows_response}"

# Initialize variables
slackThread=""

# Initialize arrays
successfulWorkflows=()
failedWorkflows=()
pendingWorkflows=()

jq -c '.[]' <<< "$workflows_response" | while read -r workflow; do
    id=$(echo "${workflow}" | jq -r '.id')
    name=$(echo "${workflow}" | jq -r '.name')
    workflow_status=$(fetch_workflow_runs "${id}")

    echo "Workflow status for ${name}:"
    echo "${workflow_status}"

    jq -c '.[]' <<< "$workflow_status" | while read -r status; do
        workflowStatus=$(echo "${status}" | jq -r '.status')
        conclusion=$(echo "${status}" | jq -r '.conclusion')
        workflowURL=$(echo "${status}" | jq -r '.URL')
        workflowStartTime=$(echo "${status}" | jq -r '.StartTime')

        echo "Workflow Status: ${workflowStatus}"
        echo "Conclusion: ${conclusion}"
        echo "URL: ${workflowURL}"
        echo "Workflow started at: ${workflowStartTime}"

        if [ -z "${workflowStatus}" ]; then
            printf ":red_circle: *$repo:* <https://github.com/${owner}/${repo}/actions/workflows/|_*${name}*_> Did not return a workflow status \n" >> slack-message.txt
        else
            if [ "${conclusion}" = "success" ]; then
                echo "Workflow $name $conclusion"
                successfulWorkflows+=("$(printf "<%s|_*%s*_> status is *%s* with conclusion *%s* \\n" "${workflowURL}" "${name}" "${workflowStatus}" "${conclusion}")")
            elif [[ "${workflowStatus}" == "waiting" ]] || [[ "${workflowStatus}" == "pending" ]] || [[ "${workflowStatus}" == "in_progress" ]] || [[ "${workflowStatus}" == "queued" ]]; then
                echo "Workflow $name $conclusion"
                pendingWorkflows+=("$(printf "<%s|_*%s*_> status is *%s* with conclusion *%s* \\n" "${workflowURL}" "${name}" "${workflowStatus}" "${conclusion}")")
            else
                echo "Workflow $name $conclusion"
                failedWorkflows+=("$(printf "<%s|_*%s*_> status is *%s* with conclusion *%s* \\n" "${workflowURL}" "${name}" "${workflowStatus}" "${conclusion}")")
            fi
        fi
    done
done

# Check if each of the arrays is empty, if not then add the relevant output to the slackThread variable to be sent to slack as a threaded update.
if [ "${#failedWorkflows[@]}" -gt 0 ]; then
    slackThread+=":red_circle: GitHub Workflows have failed! \\n$(IFS=$'\n'; echo "${failedWorkflows[*]}")\\n\\n"
fi

if [ "${#pendingWorkflows[@]}" -gt 0 ]; then
    slackThread+=":yellow_circle: GitHub Workflows are still in pending state!: \\n$(IFS=$'\n'; echo "${pendingWorkflows[*]}")\\n\\n"
fi

if [ "${#successfulWorkflows[@]}" -gt 0 ]; then
    slackThread+=":green: GitHub Workflows completed successfully: \\n$(IFS=$'\n'; echo "${successfulWorkflows[*]}")\\n\\n"
fi

echo $slackThread >> gh-workflow-status.txt
