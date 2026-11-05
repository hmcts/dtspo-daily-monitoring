#!/bin/bash
# This script expects the following options:

### Setup script environment
set -e

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
    curl -s -L -H "Accept: application/vnd.github+json" -H "Authorization: Bearer ${githubToken}" -H "X-GitHub-Api-Version: 2022-11-28" "https://api.github.com/repos/${owner}/${githubRepo}/actions/workflows/${workflow_id}/runs?per_page=100&branch=${branch}"
}

# Initialize variables
slackThread=""

# Initialize arrays
missingWorkflows=()
successfulWorkflows=()
failedWorkflows=()
pendingWorkflows=()
staleWorkflows=()

# Determine if run was a supplied value, if not then process all workflows in the repo.
if [[ -z "${run}" ]]; then
    workflows_response=$(curl -s -L -H "Accept: application/vnd.github+json" -H "Authorization: Bearer ${githubToken}" -H "X-GitHub-Api-Version: 2022-11-28" https://api.github.com/repos/${owner}/${githubRepo}/actions/workflows | jq -r '.workflows[] | {id: .id, name: .name}')
else
    workflows_response=$(curl -s -L -H "Accept: application/vnd.github+json" -H "Authorization: Bearer ${githubToken}" -H "X-GitHub-Api-Version: 2022-11-28" "https://api.github.com/repos/${owner}/${githubRepo}/actions/workflows" | jq -c --arg workflow "$run" '.workflows[] | select(.name == $workflow) | {id: .id, name: .name}')
fi

# check if a response was made
if [ -z "$workflows_response" ]; then
    echo "No workflows found or failed to fetch workflows." >&2
    missingWorkflows+=("$(printf "No workflow found in repo: %s / %s \\n" "${githubRepo}" "${run}")")
else

    workflows=$(jq -c '.' <<< "$workflows_response")

    for workflow in $workflows; do
        id=$(echo "${workflow}" | jq -r '.id')
        name=$(echo "${workflow}" | jq -r '.name')
        workflow_status=$(fetch_workflow_runs "${id}")

        latestRun=$(jq -c '.workflow_runs[0] // {}' <<< "$workflow_status")
        latestSuccessfulRun=$(jq -c '[.workflow_runs[] | select(.conclusion == "success")][0] // {}' <<< "$workflow_status")
        workflowStatus=$(jq -r '.status // empty' <<< "$latestRun")
        conclusion=$(jq -r '.conclusion // empty' <<< "$latestRun")
        workflowURL=$(jq -r '.html_url // empty' <<< "$latestRun")
        workflowStartTime=$(jq -r '.run_started_at // empty' <<< "$latestRun")
        lastSuccessTime=$(jq -r '.run_started_at // empty' <<< "$latestSuccessfulRun")

        printf 'Workflow Status: %s\n\nConclusion: %s\n\nURL: %s\n\nWorkflow started at: %s\n\nWorkflow %s %s\n\n' \
            "${workflowStatus}" "${conclusion}" "${workflowURL}" "${workflowStartTime}" "${name}" "${conclusion}"

        nowEpoch=$("${date_command}" -u +%s)
        lastSuccessEpoch=""
        if [[ -n "${lastSuccessTime}" ]]; then
            lastSuccessEpoch=$("${date_command}" -u -d "${lastSuccessTime}" +%s 2>/dev/null || true)
        fi
        if [[ -z "${lastSuccessEpoch}" ]] || (( nowEpoch - lastSuccessEpoch > 86400 || lastSuccessEpoch > nowEpoch )); then
            staleWorkflows+=("$(printf "<https://github.com/%s/%s/actions/workflows/%s|_*%s*_> has not succeeded in the last 24 hours (last success: %s)\\n" "${owner}" "${githubRepo}" "${id}" "${name}" "${lastSuccessTime:-never}")")
        fi

        if [ -z "${workflowStatus}" ]; then
            printf ":red_circle: *$repo:* <https://github.com/${owner}/${githubRepo}/actions/workflows/|_*${name}*_> Did not return a workflow status \n" >> slack-message.txt
        else
            if [ "${conclusion}" == "success" ]; then
                if [[ -n "${lastSuccessEpoch}" ]] && (( nowEpoch - lastSuccessEpoch <= 86400 && lastSuccessEpoch <= nowEpoch )); then
                    successfulWorkflows+=("$(printf "<%s|_*%s*_> status is *%s* with conclusion *%s*\\n" "${workflowURL}" "${name}" "${workflowStatus}" "${conclusion}")")
                fi
            elif [[ "${workflowStatus}" == "waiting" ]] || [[ "${workflowStatus}" == "pending" ]] || [[ "${workflowStatus}" == "in_progress" ]] || [[ "${workflowStatus}" == "queued" ]]; then
                pendingWorkflows+=("$(printf "<%s|_*%s*_> status is *%s* with conclusion *%s*\\n" "${workflowURL}" "${name}" "${workflowStatus}" "${conclusion}")")
            else
                failedWorkflows+=("$(printf "<%s|_*%s*_> status is *%s* with conclusion *%s*\\n" "${workflowURL}" "${name}" "${workflowStatus}" "${conclusion}")")
            fi
        fi
    done
fi

# Check if each of the arrays is empty, if not then add the relevant output to the slackThread variable to be sent to slack as a threaded update.
if [ "${#missingWorkflows[@]}" -gt 0 ]; then
    slackThread+=":red_circle: GitHub Workflows missing! \\n$(IFS=$'\n'; echo "${missingWorkflows[*]}")\\n\\n"
fi

if [ "${#failedWorkflows[@]}" -gt 0 ]; then
    slackThread+=":red_circle: GitHub Workflows have failed! \\n$(IFS=$'\n'; echo "${failedWorkflows[*]}")\\n\\n"
fi

if [ "${#pendingWorkflows[@]}" -gt 0 ]; then
    slackThread+=":yellow_circle: GitHub Workflows are still in pending state!: \\n$(IFS=$'\n'; echo "${pendingWorkflows[*]}")\\n\\n"
fi

if [ "${#staleWorkflows[@]}" -gt 0 ]; then
    slackThread+=":red_circle: GitHub Workflows have not succeeded in the last 24 hours: \\n$(IFS=$'\n'; echo "${staleWorkflows[*]}")\\n\\n"
fi

if [ "${#successfulWorkflows[@]}" -gt 0 ]; then
    slackThread+=":green_circle: GitHub Workflows completed successfully: \\n$(IFS=$'\n'; echo "${successfulWorkflows[*]}")\\n\\n"
fi

echo $slackThread >> workflow-status.txt
