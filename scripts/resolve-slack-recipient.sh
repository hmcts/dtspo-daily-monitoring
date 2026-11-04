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
: "${SYSTEM_PULLREQUEST_PULLREQUESTID:?SYSTEM_PULLREQUEST_PULLREQUESTID is required for pull request notifications}"

echo "Getting pull request details for PR ID ${SYSTEM_PULLREQUEST_PULLREQUESTID}"
pullRequest=$(curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/hmcts/dtspo-daily-monitoring/pulls/${SYSTEM_PULLREQUEST_PULLREQUESTID}")
githubUser=$(jq -er '.user.login' <<< "$pullRequest")
echo "Pull request authored by GitHub user $githubUser"
slackMappings=$(curl -fsSL "https://raw.githubusercontent.com/hmcts/github-slack-user-mappings/master/slack.json")
if ! slackUser=$(jq -er --arg githubUser "$githubUser" '[.[][] | select(.github | contains($githubUser)) | .slack][0] | select(type == "string" and length > 0)' <<< "$slackMappings"); then
    printf 'Unable to resolve a Slack user for PR author %s.\n' "$githubUser" >&2
    exit 1
fi
echo "Resolved Slack user for PR author $githubUser: $slackUser"

printf '%s\n' "$slackUser"
