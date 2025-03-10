#!/bin/bash

set -x

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

args=$(getopt -a -o t:c:n:h: --long slackBotToken:,slackChannelName:,help -- "$@")
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
        echo 'Please supply all of: '
        echo '- Slack token'
        echo '- Slack channel name'
        echo "------------------------"
    } >&2
    exit 1
fi

#Configuring the script
ELASTICSEARCH_HOST="10.96.85.7:9200"
OUTPUT=""
slackThread=""

# Get the list of all index names
INDEX_LIST=$(curl -sv -XGET "$ELASTICSEARCH_HOST/_cat/indices?h=index")

#Read each index from the file
while IFS= read -r index_name; do
    if [[ -n "$index_name" ]]; then
        #Get the field count for the index
        field_count=$(curl -sv -XGET "$ELASTICSEARCH_HOST/$index_name/_mapping?pretty" | grep type | wc -l)
        index_count=$(curl -sv -XGET "$ELASTICSEARCH_HOST/_cat/indices" | awk '{print $3, $7}' | grep $index_name)
        
        # Append the result to the output variable
        if [[ $field_count -ge 5500 ]]; then
        OUTPUT+="$index_count:  Field Count - $field_count"$'\n'
        fi
    fi

done <<< "$INDEX_LIST"

Field_Count_Status=":red_circle:"
if (( -z "$OUTPUT" )); then
    Field_Count_Status=":green_circle:"
fi

echo "$OUTPUT"

if [[ "$Field_Count_Status" == ":red_circle:" && $(grep -c '' <<< "$VARIABLE") -le 2 ]]; then
        slackNotification $slackBotToken $slackChannelName ":elasticserch: $Field_Count_Status Elastic indexes approaching limits" "The following indices have more than 5500 fields: " $'\n' "TEST$OUTPUT"
elif [[ "$Field_Count_Status" == ":red_circle:" && $(grep -c '' <<< "$VARIABLE") -ge 3 ]]; then
        slackNotification $slackBotToken $slackChannelName ":elasticserch: $Field_Count_Status Elastic indexes approaching limits"
        slackThreadResponse $slackBotToken $slackChannelName "The following indices have more than 5500 fields: " $'\n' "TEST$OUTPUT" $TS
fi