#!/usr/bin/env bash

set -euo pipefail

defaultChannel=${1:?Usage: $0 <default-channel>}

if [[ "${BUILD_REASON:-}" != "PullRequest" ]]; then
    printf '%s\n' "$defaultChannel"
    exit 0
fi

: "${GITHUB_TOKEN:?GITHUB_TOKEN is required for pull request notifications}"
: "${SYSTEM_PULLREQUEST_PULLREQUESTID:?SYSTEM_PULLREQUEST_PULLREQUESTID is required for pull request notifications}"

pullRequest=$(curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/hmcts/dtspo-daily-monitoring/pulls/${SYSTEM_PULLREQUEST_PULLREQUESTID}")
githubUser=$(jq -er '.user.login' <<< "$pullRequest")
slackMappings=$(curl -fsSL "https://raw.githubusercontent.com/hmcts/github-slack-user-mappings/master/slack.json")
slackUser=$(jq -er --arg githubUser "$githubUser" '[.[][] | select(.github | contains($githubUser)) | .slack][0] | select(type == "string" and length > 0)' <<< "$slackMappings")

printf '%s\n' "$slackUser"
