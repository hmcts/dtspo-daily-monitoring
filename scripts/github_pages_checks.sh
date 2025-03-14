#!/usr/bin/env bash

# This script will curl the output of the pages found in the URLS array and use JQ to parse the output for specific information
# The URLs must return valid JSON for JQ to parse it and be of a similar format to those found below i.e. GitHub pages API output.
# Note, if you are running this script on MacOS, the BSD date command works differently. Use `gdate` to get the same output as below.

### Setup script environment
set -euo pipefail

# Source central functions script
source scripts/common-functions.sh

slackBotToken=
slackChannelName=

usage(){
>&2 cat << EOF
    ------------------------------------------------
    Script to check GitHub page expiry
    ------------------------------------------------
    Usage: $0
        [ -t | --slackBotToken ]
        [ -c | --slackChannelName ]
        [ -h | --help ]
EOF
exit 1
}

args=$(getopt -a -o t:c:p:g: --long slackBotToken:,slackChannelName:,help -- "$@")
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
        # -- means the end of the arguments; drop this, and break out of the while loop
        --) shift; break ;;
        *) >&2 echo Unsupported option: $1
            usage ;;
    esac
done

if [[ -z "$slackBotToken" || -z "$slackChannelName" ]]; then
    {
        echo "------------------------"
        echo 'Please supply all of'
        echo '- Slack token'
        echo '- Slack channel name' >&2
        echo "------------------------"
        exit 1
    } >&2
    exit 1
fi

### Script begins
CURRENTDATE=$($date_command +"%Y-%m-%d") # 2w = 2 weeks
EXPIRETHRESHOLD=$($date_command -u +"%Y-%m-%d" -d "+2 weeks") # 2w = 2 weeks

declare -a URLS=("https://hmcts.github.io/api/pages.json" "https://hmcts.github.io/ops-runbooks/api/pages.json")
declare -a PAGES

# scrapeURLs will loop over each URL found in the URLS array and replace the short form URLs in the records
# with a complete URL that it will then save into an array called PAGES
function scrapeUrls() {
    for URL in ${URLS[@]}; do
        local STRIPSUFFIX="/api/pages.json"
        local BASE_URL="${URL%$STRIPSUFFIX}"
        PAGES+=$(curl -s $URL | jq '.[] | select(.url | contains("search/index.html") | not) | .url |= sub("\\.\\."; "'$BASE_URL'")')
    done
}

function reviewURLs() {
    NULLFOUNDURLs=$(jq -rc '. | select(.review_by == null) | "> "+"<" + .url + "|" + .title + ">"' <<<$PAGES)
    EXPIREDFOUNDURLs=$(jq -c '. | select(.review_by != null and .review_by < "'$CURRENTDATE'") | "> "+"<" + .url + "|" + .title + ">"' <<<$PAGES)
    EXPIRINGFOUNDURLs=$(jq -c '. | select(.review_by != null and .review_by < "'$EXPIRETHRESHOLD'" and .review_by > "'$CURRENTDATE'") | "> "+"<" + .url + "|" + .title + ">"' <<<$PAGES)
}

# findNullUrls will search through all records for a review_by field set to null i.e. when no date has been set on that page
# If found it will print a list of the pages found in a slack hyperlink format so it is clickable
function findNullUrls() {

    if [ -n "$NULLFOUNDURLs" ]; then
        local URLS=$(printf "%s\n\n" "$NULLFOUNDURLs" | tr -d '"')

        slackThreadResponse $slackBotToken $slackChannelName ":red_circle: Pages found with no review date set! \\n$URLS" $TS
    fi
}

# findExpiredUrls will search through all records for a review_by data older than the current date
# If found it will print a list of the pages found in a slack hyperlink format so it is clickable
function findExpiredUrls() {

    if [ -n "$EXPIREDFOUNDURLs" ]; then
        local URLS=$(printf "%s\n\n" "$EXPIREDFOUNDURLs" | tr -d '"')

        slackThreadResponse $slackBotToken $slackChannelName ":red_circle: Pages found which have an expired review date! \\n$URLS" $TS
    fi
}

# findExpiringUrls will search through all records for a review_by data within the next 14days.
# If found it will print a list of the pages found in a slack hyperlink format so it is clickable.
function findExpiringUrls() {

    if [ -n "$EXPIRINGFOUNDURLs" ]; then
        local URLS=$(printf "%s\n\n" "$EXPIRINGFOUNDURLs" | tr -d '"')

        slackThreadResponse $slackBotToken $slackChannelName ":yellow_circle: Pages found which require a review in the next 13 days! \\n$URLS" $TS
    fi
}

# Scrape sites in list for pages to review
scrapeUrls
reviewURLs

STATUS=":green_circle:"
if [[ -n "$NULLFOUNDURLs"  || -n "$EXPIREDFOUNDURLs" ]]; then
    STATUS=":red_circle:"
elif [[ -n "$EXPIRINGFOUNDURLs" ]]; then
    STATUS=":yellow_circle:"
fi

if [[ "$STATUS" == ":red_circle:" || "$STATUS" == ":yellow_circle:" ]]; then
    # Post initial header message
    slackNotification $slackBotToken $slackChannelName "$STATUS Documentation Review" ":github: <https://hmcts.github.io|*_HMCTS Way_*> and <https://hmcts.github.io/ops-runbooks|*_Ops Runbook_*> Status :document_it:"

    # Run checks on scraped pages to find the review dates and outcomes for each.
    findNullUrls
    findExpiredUrls
    findExpiringUrls
fi
