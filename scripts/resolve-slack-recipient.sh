#!/usr/bin/env bash

set -euo pipefail

defaultChannel=${1:?Usage: $0 <default-channel>}

if [[ "${BUILD_REASON:-}" != "PullRequest" ]]; then
    if [[ "${BUILD_SOURCEBRANCH:-}" == "refs/heads/master" ]]; then
        printf '%s\n' "$defaultChannel"
        exit 0
    fi
    echo "Slack notifications require a master build or a pull request build." >&2
    exit 1
fi

: "${GITHUB_TOKEN:?GITHUB_TOKEN is required for pull request notifications}"
pullRequestNumber=${SYSTEM_PULLREQUEST_PULLREQUESTNUMBER:-}
if [[ ! "$pullRequestNumber" =~ ^[0-9]+$ ]]; then
    pullRequestNumber=${SYSTEM_PULLREQUEST_PULLREQUESTID:-}
fi
if [[ ! "$pullRequestNumber" =~ ^[0-9]+$ ]]; then
    echo "A numeric GitHub pull request number is required." >&2
    exit 1
fi

printf 'Getting pull request details for PR #%s\n' "$pullRequestNumber" >&2
if ! pullRequest=$(curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/hmcts/dtspo-daily-monitoring/pulls/${pullRequestNumber}"); then
    echo "GitHub PR lookup failed. Check the PR number and token repository access; GitHub can return 404 for inaccessible repositories." >&2
    exit 1
fi
githubUser=$(jq -er '.user.login' <<< "$pullRequest")
echo "Pull request authored by GitHub user $githubUser" >&2
if ! slackMappings=$(curl -fsSL "https://raw.githubusercontent.com/hmcts/github-slack-user-mappings/master/slack.json"); then
    echo "Slack mapping download failed. Check the github-slack-user-mappings repository, branch and slack.json path." >&2
    exit 1
fi
if ! slackUser=$(jq -er --arg githubUser "$githubUser" '[.[][] | select(.github | contains($githubUser)) | .slack][0] | select(type == "string" and length > 0)' <<< "$slackMappings"); then
    printf 'Unable to resolve a Slack user for PR author %s.\n' "$githubUser" >&2
    exit 1
fi
echo "Resolved Slack user for PR author $githubUser: $slackUser" >&2

printf '%s\n' "$slackUser"
