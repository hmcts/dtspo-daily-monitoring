#!/bin/bash
az extension add --name front-door --yes

# Check platform
platform=$(uname)

# Check and install missing packages
if [[ $platform == "Darwin" ]]; then
    date_command=$(which gdate)
elif [[ $platform == "Linux" ]]; then
    date_command=$(which date)
fi

# Azure CLI command to populate URL list
subscription=$1
resource_group=$2
front_door_name=$3

# Minimum number days before a notification is sent
min_cert_expiration_days=$4

# Function to check certificate expiration
check_certificate_expiration() {
    url=$1
    echo "https://$url"
    expiration_date=$(echo | openssl s_client -servername "${url}" -connect "${url}:443" 2>/dev/null | openssl x509 -noout -dates 2>/dev/null | grep "notAfter" | cut -d "=" -f 2)    
    echo $expiration_date
    if [[ -n $expiration_date ]]; then
        expiration_timestamp=$($date_command -d "${expiration_date}" +%s)
        current_timestamp=$($date_command +%s)
        seconds_left=$((expiration_timestamp - current_timestamp))
        days_left=$((seconds_left / 86400))
        if [[ $days_left -le 0 ]]; then
             echo "> :red_circle: Certificate for (*${front_door_name}*) *${url}* has expired *${days_left}* days ago." >> slack-message.txt
             has_results=true
        elif [[ $days_left -le min_cert_expiration_days ]]; then
             echo "> :yellow_circle: Certificate for (*${front_door_name}*) *${url}* expires in *${days_left}* days." >> slack-message.txt
             has_results=true
        fi
    fi
}

# Azure CLI command to populate URL list

urls=$(az afd custom-domain list --subscription "$subscription" --resource-group "$resource_group" --profile-name "$front_door_name" --query "[].hostName" -o tsv)

# Check certificate expiration for each URL
has_results=false
for url in $urls; do
    check_certificate_expiration "${url}"
done

# If there are no results, append a message to indicate no expiring certificates 
if [[ $has_results == false ]]; then
    echo "> :green_circle: No certificates for (*${front_door_name}*) are expiring within the specified threshold." >> slack-message.txt
fi
