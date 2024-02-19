#!/bin/bash

# This script will curl the output of the pages found in the URLS array and use JQ to parse the output for specific information
# The URLs must return valid JSON for JQ to parse it and be of a similar format to those found below i.e. GitHub pages API output.
# Note, if you are running this script on MacOS, the BSD date command works differently. Use `gdate` to get the same output as below.

CURRENTDATE=$(date +"%Y-%m-%d") # 2w = 2 weeks
EXPIRETHRESHOLD=$(date -u +"%Y-%m-%d" -d "+2 weeks") # 2w = 2 weeks

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

# findNullUrls will search through all records for a review_by field set to null i.e. when no date has been set on that page
# If found it will print a list of the pages found in a slack hyperlink format so it is clickable
function findNullUrls() {

    NULLFOUNDURLs=$(jq -rc '. | select(.review_by == null) | "> "+"<" + .url + "|" + .title + ">"' <<<$PAGES) 

    if [ -n "$NULLFOUNDURLs" ]; then
        printf ">:red_circle: Pages found with no review date set: \n\n" >> slack-message.txt
        printf "%s\n\n" "$NULLFOUNDURLs" >> slack-message.txt
    fi
}

# findExpiredUrls will search through all records for a review_by data older than the current date
# If found it will print a list of the pages found in a slack hyperlink format so it is clickable
function findExpiredUrls() {

    EXPIREDFOUNDURLs=$(jq -c '. | select(.review_by != null and .review_by < "'$CURRENTDATE'") | "> "+"<" + .url + "|" + .title + ">"' <<<$PAGES)

    if [ -n "$EXPIREDFOUNDURLs" ]; then
        printf "\n>:red_circle: Pages found which have an expired review date: \n\n" >> slack-message.txt
        # printf "%s\n\n" "$EXPIREDFOUNDURLs" >> slack-message.txt
    fi
}

# findExpiringUrls will search through all records for a review_by data within the next 14days.
# If found it will print a list of the pages found in a slack hyperlink format so it is clickable.
# If none found it will print an all green message stating so.
function findExpiringUrls() {

    EXPIRINGFOUNDURLs=$(jq -c '. | select(.review_by != null and .review_by < "'$EXPIRETHRESHOLD'") | "> "+"<" + .url + "|" + .title + ">"' <<<$PAGES)

    if [ -n "$EXPIRINGFOUNDURLs" ]; then
        printf "\n>:yellow_circle: Pages found which require a review in the next 13 days: \n\n" >> slack-message.txt
        # printf "%s\n\n" "$EXPIRINGFOUNDURLs" >> slack-message.txt
    else
        printf "\n>:green_circle: All pages have acceptable review dates! :smile: \n\n" >> slack-message.txt
    fi
}

scrapeUrls
printf "\n\n:github: :document_it: <https://hmcts.github.io|*_HMCTS Way_*> and <https://hmcts.github.io/ops-runbooks|*_Ops Runbook_*> status: \n\n" >> slack-message.txt

findNullUrls
findExpiredUrls
findExpiringUrls
