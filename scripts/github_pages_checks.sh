#!/usr/bin/env bash

# This script will curl the output of the pages found in the URLS array and use JQ to parse the output for specific information
# The URLs must return valid JSON for JQ to parse it and be of a similar format to those found below i.e. GitHub pages API output.
# Note, if you are running this script on MacOS, the BSD date command works differently. Use `gdate` to get the same output as below.

### Setup script environment
set -euox pipefail

# Source central functions script
source scripts/common-functions.sh

slackBotToken=
slackChannelName=
pullRequestNumber=
githubToken=

usage(){
>&2 cat << EOF
------------------------------------------------
Script to check GitHub page expiry
------------------------------------------------
Usage: $0
    [ -t | --slackBotToken ]
    [ -c | --slackChannelName ]
    [ -p | --pullRequestNumber ]
    [ -g | --githubToken ]
    [ -h | --help ]
EOF
exit 1
}

args=$(getopt -a -o t:c:p:g: --long slackBotToken:,slackChannelName:,pullRequestNumber:,githubToken:,help -- "$@")
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
        -p | --pullRequestNumber) pullRequestNumber=$2     ; shift 2 ;;
        -g | --githubToken)       githubToken=$2           ; shift 2 ;;
        # -- means the end of the arguments; drop this, and break out of the while loop
        --) shift; break ;;
        *) >&2 echo Unsupported option: $1
            usage ;;
    esac
done

if [ -z "$slackBotToken" ]; then
        echo "------------------------"
        echo 'Please supply a Slack token' >&2
        echo "------------------------"
        exit 1
fi

# Check if either slackChannelName or (pullRequestNumber and githubToken) are supplied
if [ -n "$slackChannelName" ] && [ -z "$pullRequestNumber" ] && [ -z "$githubToken" ]; then
    echo "Running on Main"
elif [ -z "$slackChannelName" ] && [ -n "$pullRequestNumber" ] && [ -n "$githubToken" ]; then
    echo "Running on PR"
else
    echo "------------------------"
    echo "Error: You must supply either slackChannelName OR both pullRequestNumber and githubToken."
    echo "------------------------"
    exit 1
fi

### Script begins
CURRENTDATE=$($date_command +"%Y-%m-%d") # 2w = 2 weeks
EXPIRETHRESHOLD=$($date_command -u +"%Y-%m-%d" -d "+2 weeks") # 2w = 2 weeks

declare -a URLS=("https://hmcts.github.io/api/pages.json" "https://hmcts.github.io/ops-runbooks/api/pages.json")
declare -a PAGES

# check if this is a PR run i.e. did we supply githubToken and pullRequestNumber via CI
# If true the Slack Channel Name will be set to the GitHub user of the PR
if isPR "$githubToken" "$pullRequestNumber"; then
    echo "This is a Pull Request. PR Channel Name: $PR_CHANNEL_NAME"
    slackChannelName=$PR_CHANNEL_NAME
fi


# scrapeURLs will loop over each URL found in the URLS array and replace the short form URLs in the records
# with a complete URL that it will then save into an array called PAGES
function scrapeUrls() {
    for URL in ${URLS[@]}; do
        local STRIPSUFFIX="/api/pages.json"
        local BASE_URL="${URL%$STRIPSUFFIX}"
        PAGES+=$(curl -s $URL | jq '.[] | select(.url | contains("search/index.html") | not) | .url |= sub("\\.\\."; "'$BASE_URL'")')
    done
}

# findNullUrls will search through all records for a review_by field set to null i.e. when no date has been set on that page
# If found it will print a list of the pages found in a slack hyperlink format so it is clickable
function findNullUrls() {

    NULLFOUNDURLs=$(jq -rc '. | select(.review_by == null) | "<" + .url + "|" + .title + ">"' <<<$PAGES)

    if [ -n "$NULLFOUNDURLs" ]; then
        local URLS=$(printf "%s\n\n" "$NULLFOUNDURLs" | tr -d '"')

        post_message $slackBotToken $slackChannelName ">:red_circle: Pages found with no review date set! \n\n"
        post_threaded_reply $slackBotToken $slackChannelName "$URLS" $TS #$TS is an output of the post_message function
    fi
}

# findExpiredUrls will search through all records for a review_by data older than the current date
# If found it will print a list of the pages found in a slack hyperlink format so it is clickable
function findExpiredUrls() {

    EXPIREDFOUNDURLs=$(jq -c '. | select(.review_by != null and .review_by < "'$CURRENTDATE'") | "<" + .url + "|" + .title + ">"' <<<$PAGES)

    if [ -n "$EXPIREDFOUNDURLs" ]; then

        local URLS=$(printf "%s\n\n" "$EXPIREDFOUNDURLs" | tr -d '"')
        post_message $slackBotToken $slackChannelName "\n>:red_circle: Pages found which have an expired review date! \n\n"
        post_threaded_reply $slackBotToken $slackChannelName "$URLS" $TS #$TS is an output of the post_message function
    fi
}

# findExpiringUrls will search through all records for a review_by data within the next 14days.
# If found it will print a list of the pages found in a slack hyperlink format so it is clickable.
# If none found it will print an all green message stating so.
function findExpiringUrls() {

    EXPIRINGFOUNDURLs=$(jq -c '. | select(.review_by != null and .review_by < "'$EXPIRETHRESHOLD'" and .review_by > "'$CURRENTDATE'") | "> "+"<" + .url + "|" + .title + ">"' <<<$PAGES)

    if [ -n "$EXPIRINGFOUNDURLs" ]; then
        post_message $slackBotToken $slackChannelName  "\n>:yellow_circle: Pages found which require a review in the next 13 days! \n\n"
        post_threaded_reply $slackBotToken $slackChannelName "$EXPIRINGFOUNDURLs" $TS
    fi
}

function findGoodUrls() {
    if [[ -z "$EXPIRINGFOUNDURLs" && -z "$EXPIREDFOUNDURLs" ]]; then
        post_message $slackBotToken $slackChannelName "\n>:green_circle: All pages have acceptable review dates! :smile: \n\n"
    fi
}

# Scrape sites in list for pages to review
scrapeUrls

# Post initial header message
post_message $slackBotToken $slackChannelName "\n\n:github: :document_it: <https://hmcts.github.io|*_HMCTS Way_*> and <https://hmcts.github.io/ops-runbooks|*_Ops Runbook_*> status: \n\n"

# Run checks on scraped pages to find the review dates and outcomes for each.
findNullUrls
findExpiredUrls
findExpiringUrls
findGoodUrls
