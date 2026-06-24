#!/usr/bin/env bash

### Setup script environment
set -euo pipefail

# Source central functions script
source scripts/common-functions.sh

subscription=
keyVaultName=
minCertExpirationDays=14 # Minimum number of days before a notification is sent

usage(){
>&2 cat << EOF
------------------------------------------------
Script to check KeyVault certificate expiry
------------------------------------------------
Usage: $0
    [ -s | --subscription ]
    [ -k | --keyVaultName ]
    [ -e | --minCertExpirationDays ]
    [ -h | --help ]
EOF
exit 1
}

args=$(getopt -a -o s:k:e:h --long subscription:,keyVaultName:,minCertExpirationDays:,help -- "$@")
if [[ $? -gt 0 ]]; then
    usage
fi

eval set -- ${args}
while :
do
    case $1 in
        -h | --help)                    usage                       ; shift   ;;
        -s | --subscription)            subscription=$2             ; shift 2 ;;
        -k | --keyVaultName)            keyVaultName=$2             ; shift 2 ;;
        -e | --minCertExpirationDays)   minCertExpirationDays=$2    ; shift 2 ;;
        # -- means the end of the arguments; drop this, and break out of the while loop
        --) shift; break ;;
        *) >&2 echo Unsupported option: $1
            usage ;;
    esac
done

if [[ -z "$subscription" || -z "$keyVaultName" ]]; then
    {
        echo "------------------------"
        echo 'Please supply all of: '
        echo '- Subscription'
        echo '- KeyVault name'
        echo "------------------------"
    } >&2
    exit 1
fi

# Check if KeyVault exists
kvExists=$(az keyvault list --subscription "$subscription" --query "[?name=='$keyVaultName'].name" -o tsv)

if [[ -z "$kvExists" ]]; then
    echo "KeyVault $keyVaultName does not exist in subscription $subscription"
    exit 0
fi

# Initialize variables
slackThread=""

# Print initial message for the thread response to the initial heading message
slackThread+="\\n"
slackThread+="Certificate checks for KeyVault: $keyVaultName (Subscription: $subscription)\\n\\n"

# Initialize arrays
expiredCerts=()
expiringCertsUrgent=()
expiringCertsSoon=()

# Retrieve certificates from Azure KeyVault
certificates=$(az keyvault certificate list --vault-name "$keyVaultName" --subscription "$subscription" --query "[].{name:name,id:id}" -o json)

certCount=$(echo "$certificates" | jq -r '. | length')

if [[ $certCount -eq 0 ]]; then
    slackThread+=":information_source: No certificates found in KeyVault *${keyVaultName}*\\n\\n"
else
    # Function to check certificate expiration date and categorize results
    checkCertExpirationDate() {
        local certName=$1
        local certId=$2

        echo "Processing certificate: $certName"
        
        # Get certificate details including expiration date
        certDetails=$(az keyvault certificate show --vault-name "$keyVaultName" --name "$certName" --subscription "$subscription" -o json 2>/dev/null)
        
        if [[ -z "$certDetails" ]]; then
            echo "Could not retrieve details for certificate: $certName"
            return
        fi

        # Extract expiration date
        expirationDate=$(echo "$certDetails" | jq -r '.attributes.expires // empty')
        enabled=$(echo "$certDetails" | jq -r '.attributes.enabled // true')
        
        if [[ -z "$expirationDate" || "$expirationDate" == "null" ]]; then
            echo "No expiration date found for certificate: $certName"
            return
        fi

        # Calculate days until expiration
        expirationTimestamp=$($date_command -d "${expirationDate}" +%s 2>/dev/null || $date_command -j -f "%Y-%m-%dT%H:%M:%S" "${expirationDate%+*}" +%s 2>/dev/null)
        currentTimestamp=$($date_command +%s)
        secondsLeft=$((expirationTimestamp - currentTimestamp))
        daysLeft=$((secondsLeft / 86400))

        # Create portal URL for the certificate
        kvResourceId=$(az keyvault show --name "$keyVaultName" --subscription "$subscription" --query id -o tsv)
        certURL="https://portal.azure.com/#@HMCTS.NET/resource${kvResourceId}/certificates"

        # Categorize based on days left
        if [[ $daysLeft -le 0 ]]; then
            expiredCerts+=("$(printf "<%s|*%s*> in *%s*: Certificate *%s* expired *%d* days ago! (Enabled: %s)\\n" "${certURL}" "${keyVaultName}" "${subscription}" "${certName}" "$((daysLeft * -1))" "${enabled}")")
        elif [[ $daysLeft -le 7 ]]; then
            expiringCertsUrgent+=("$(printf "<%s|*%s*> in *%s*: Certificate *%s* expires in *%d* days! (Enabled: %s)\\n" "${certURL}" "${keyVaultName}" "${subscription}" "${certName}" "${daysLeft}" "${enabled}")")
        elif [[ $daysLeft -le $minCertExpirationDays ]]; then
            expiringCertsSoon+=("$(printf "<%s|*%s*> in *%s*: Certificate *%s* expires in *%d* days (Enabled: %s)\\n" "${certURL}" "${keyVaultName}" "${subscription}" "${certName}" "${daysLeft}" "${enabled}")")
        fi
    }

    # Loop over each certificate to check its expiration
    while read -r cert; do
        certName=$(echo "$cert" | jq -r '.name')
        certId=$(echo "$cert" | jq -r '.id')
        checkCertExpirationDate "${certName}" "${certId}"
    done < <(echo "$certificates" | jq -c '.[]')
fi

# Build slack thread message based on results
if [[ "${#expiredCerts[@]}" -gt 0 ]]; then
    slackThread+=":red_circle: *Expired certificates found!*\\n$(IFS=$'\n'; echo "${expiredCerts[*]}")\\n\\n"
fi

if [[ "${#expiringCertsUrgent[@]}" -gt 0 ]]; then
    slackThread+=":red_circle: *Certificates expiring very soon (within 7 days)!*\\n$(IFS=$'\n'; echo "${expiringCertsUrgent[*]}")\\n\\n"
fi

if [[ "${#expiringCertsSoon[@]}" -gt 0 ]]; then
    slackThread+=":yellow_circle: *Certificates expiring soon (within ${minCertExpirationDays} days):*\\n$(IFS=$'\n'; echo "${expiringCertsSoon[*]}")\\n\\n"
fi

# If no issues found, add success message
if [[ "${#expiredCerts[@]}" -eq 0 && "${#expiringCertsUrgent[@]}" -eq 0 && "${#expiringCertsSoon[@]}" -eq 0 && $certCount -gt 0 ]]; then
    slackThread+=":tada: :green_circle: No certificates in *${keyVaultName}* are expiring within the specified threshold.\\n\\n"
fi

# Save output to file
echo -e "$slackThread" >> keyvault-cert-status.txt
