
#!/usr/bin/env bash

### Setup script environment
set -euo pipefail

# Source central functions script
source scripts/common-functions.sh

slackBotToken=
slackChannelName=
subscription=
resourceGroup=
frontdoorName=
minCertExpirationDays=14 # Minimum number days before a notification is sentdate_command

usage(){
>&2 cat << EOF
------------------------------------------------
Script to check GitHub page expiry
------------------------------------------------
Usage: $0
    [ -t | --slackBotToken ]
    [ -c | --slackChannelName ]
    [ -s | --subscription ]
    [ -r | --resourceGroup ]
    [ -f | --frontdoorName ]
    [ -e | --minCertExpirationDays ]
    [ -h | --help ]
EOF
exit 1
}

args=$(getopt -a -o t:c:s:r:f:e:h: --long slackBotToken:,slackChannelName:,subscription:,resourceGroup:,frontdoorName:,minCertExpirationDays:,help -- "$@")
if [[ $? -gt 0 ]]; then
    usage
fi

eval set -- ${args}
while :
do
    case $1 in
        -h | --help)                    usage                       ; shift   ;;
        -t | --slackBotToken)           slackBotToken=$2            ; shift 2 ;;
        -c | --slackChannelName)        slackChannelName=$2         ; shift 2 ;;
        -c | --subscription)            subscription=$2             ; shift 2 ;;
        -c | --resourceGroup)           resourceGroup=$2            ; shift 2 ;;
        -c | --frontdoorName)           frontdoorName=$2            ; shift 2 ;;
        -c | --minCertExpirationDays)   minCertExpirationDays=$2    ; shift 2 ;;
        # -- means the end of the arguments; drop this, and break out of the while loop
        --) shift; break ;;
        *) >&2 echo Unsupported option: $1
            usage ;;
    esac
done

if [[ -z "$slackBotToken" || -z "$slackChannelName" || -z "$subscription" || -z "$resourceGroup" || -z "$frontdoorName" ]]; then
    {
        echo "------------------------"
        echo 'Please supply all of: '
        echo '- Slack token'
        echo '- Slack channel name'
        echo '- Subscription'
        echo '- Resource Group name'
        echo '- Frontdoor name'
        echo "------------------------"
    } >&2
    exit 1
fi

# Ensure az module is available
az extension add --name front-door --yes

# Initialize variables
slackThread=""

# Print initial message for the thread response to the initial heading message
slackThread+="\\n\\n"
slackThread+="Certificate checks for: $frontdoorName\\n\\n"

# Initialize array
results=()

# Retrieve URLs from Azure for named Frontdoor instance
urls=$(az afd custom-domain list --subscription "$subscription" --resource-group "$resourceGroup" --profile-name "$frontdoorName" --query "[].hostName" -o tsv)

# Function to check certificate expiration date and save result to results() array.
checkCertExpirationDate() {
    url=$1
    expiration_date=$(echo | openssl s_client -servername "${url}" -connect "${url}:443" 2>/dev/null | openssl x509 -noout -dates 2>/dev/null | grep "notAfter" | cut -d "=" -f 2)
    if [[ -n $expiration_date ]]; then
        expiration_timestamp=$($date_command -d "${expiration_date}" +%s)
        current_timestamp=$($date_command +%s)
        seconds_left=$((expiration_timestamp - current_timestamp))
        days_left=$((seconds_left / 86400))
        if [[ $days_left -le 0 ]]; then
            results+=("$(printf ":red_circle: Certificate for *%s* : *%s* expired *%s* days ago! \\n" "${frontdoorName}" "${url}" "${days_left}")")
        elif [[ $days_left -le min_cert_expiration_days ]]; then
            results+=("$(printf ":yellow_circle: Certificate for *%s* : *%s* expires in *%s* days! \\n" "${frontdoorName}" "${url}" "${days_left}")")
        fi
    fi
}

# Loop over each URL to check its certificate expiration
for url in $urls; do
    checkCertExpirationDate "${url}"
done

# If results contains anything, save to slackThread variable, if nothing found save an all good status
if [ "${#results[@]}" -gt 0 ]; then
    slackThread+="These certificates need reviewed: \\n$(IFS=$'\n'; echo "${results[*]}")\\n\\n"
else
    slackThread+=":tada: :green_circle: No certificates for *${frontdoorName}* are expiring within the specified threshold.\\n\\n"
fi

# Save output to file
echo $slackThread >> cert-status.txt
