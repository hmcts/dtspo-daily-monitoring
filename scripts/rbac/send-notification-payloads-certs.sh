#!/usr/bin/env bash

set -euo pipefail

source scripts/common-functions.sh

usage() {
  cat >&2 <<'EOF'
Build and send Slack + Teams certificate notifications from JSON files.

Usage:
  scripts/build-notification-payloads.sh \
    --header <text> \
    --subheading <text> \
    [--slackBotToken <token> --slackChannelName <channel>] \
    [--teamsTeamId <team-id> --teamsChannelId <channel-id>]

Required:
  --expiringJson      target file: ${outputPrefix}certificates-expiring.json"
  --header             Notification header
  --subheading         Notification subheading

Optional targets (if no target, dumps valid/expired as txt ):
  Slack:
    --slackBotToken
    --slackChannelName

  Teams (az account must be logged in with passed $EADEVOPS_PASSWORD):
    --teamsTeamId
    --teamsChannelId
EOF
}

expiringJson=""
header=""
subheading=""
slackBotToken=""
slackChannelName=""
teamsTeamId=""
teamsChannelId=""
outputPrefix=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --expiringJson) expiringJson="$2"; shift 2 ;;
    --header) header="$2"; shift 2 ;;
    --subheading) subheading="$2"; shift 2 ;;
    --slackBotToken) slackBotToken="$2"; shift 2 ;;
    --slackChannelName) slackChannelName="$2"; shift 2 ;;
    --teamsTeamId) teamsTeamId="$2"; shift 2 ;;
    --teamsChannelId) teamsChannelId="$2"; shift 2 ;;
    --outputPrefix) outputPrefix="$2"; shift 2 ;;
    *) echo "Unsupported arg: $1" >&2; exit 1 ;;
  esac
done

# always required
# todo The “always required” check uses || (any of expiringJson, header, subheading) instead of && (all three). Your pipeline does pass all three, so it won’t trip, but semantically you may want &&.
if ! [[ -n "$expiringJson" && -n "$header" || -n "$subheading" ]]; then
  echo "Missing required args jsons or the header/subheader" >&2
  exit 1
fi
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
command -v az >/dev/null 2>&1 || { echo "az is required" >&2; exit 1; } # for teams

# intend to send slack msg, check prereqs
sendSlack=0
if [[ -n "$slackBotToken" || -n "$slackChannelName" ]]; then
  # if either is set, require both
  if ! [[ -n "$slackBotToken" && -n "$slackChannelName" ]]; then
    echo "Provide both --slackBotToken and --slackChannelName" >&2
    exit 1
  fi
  sendSlack=1
fi

# intend to send Teams msg, check prereqs
sendTeams=0
if [[ -n "$teamsTeamId" || -n "$teamsChannelId" || -n "${EADEVOPS_PASSWORD:-}" ]]; then
  # provide all 3
  if ! [[ -n "$teamsTeamId" && -n "$teamsChannelId" && -n "${EADEVOPS_PASSWORD:-}" ]]; then 
    echo "Provide both --teamsTeamId and --teamsChannelId + user's password" >&2; exit 1;
  fi
  sendTeams=1
fi

build_shared_context() {
  local expiring_path="$1"
  # jq null input (build payload), compact output
  jq -cn \
    --slurpfile expiring "$expiring_path" '
      (
        if ($expiring | length) == 0 then
          []
        elif (($expiring[0] | type) == "array") then
          ($expiring[0] // [])
        elif (($expiring[0] | type) == "object" and ($expiring[0] | has("certificates"))) then
          ($expiring[0].certificates // [])
        else
          $expiring
        end
      ) as $expiringCerts |
      {
        expiringCount: ($expiringCerts | length),
        tableHeader: "STATUS   | PKI Path        | Common Name (CN)                    | Expiry Date           | Days Left",
        tableDivider: "---------|-----------------|-------------------------------------|-----------------------|---------",
        rows: (
          $expiringCerts
          | map({
              status: "EXPIRING",
              pkiPath: (.pkiPath // "-"),
              commonName: (.commonName // "-"),
              expiryDateHuman: (.expiryDateHuman // "-"),
              daysLeft: ((.daysLeft // "-") | tostring)
            })
        )
      }
    '
}

build_common_body() {
  local context="$1"

  {
    printf "%-8s | %-15s | %-35s | %-21s | %9s\n" "STATUS" "PKI Path" "Common Name (CN)" "Expiry Date" "Days Left"
    printf "%s\n" "---------|-----------------|-------------------------------------|-----------------------|---------"

    echo "$context" | jq -r '.rows[] | [.status, .pkiPath, .commonName, .expiryDateHuman, (.daysLeft|tostring)] | @tsv' |
      while IFS=$'\t' read -r status pkiPath commonName expiryDateHuman daysLeft; do
        printf "%-8s | %-15s | %-35.35s | %-21s | %9s\n" \
          "$status" "$pkiPath" "$commonName" "$expiryDateHuman" "$daysLeft"
      done
  }
}

sharedContext=$(build_shared_context "$expiringJson")
expiringCount=$(echo "$sharedContext" | jq -r '.expiringCount')

if [[ "$expiringCount" -eq 0 ]]; then
  echo "No expiring certificates found. No notifications sent."
  exit 0
fi

commonBody=$(build_common_body "$sharedContext")

if [[ "$sendSlack" -eq 1 ]]; then
  slackNotification "$slackBotToken" "$slackChannelName" "$header" "$subheading"
  slackThreadResponse "$slackBotToken" "$slackChannelName" "\`\`\`
${commonBody}
\`\`\`" "$TS"
fi

if [[ "$sendTeams" -eq 1 ]]; then
  az login -u eadevops@hmcts.net -p "$EADEVOPS_PASSWORD" --allow-no-subscriptions 1>/dev/null
  azToken=$(az account get-access-token --resource-type ms-graph | jq -r '.accessToken')
  [[ -n "$azToken" && "$azToken" != "null" ]] || { echo "Failed to get Graph API token" >&2; exit 1; }

  teamsGraphNotification "$azToken" "$teamsTeamId" "$teamsChannelId" "$header" "$subheading" "$commonBody"
fi

echo "Sent notifications"
