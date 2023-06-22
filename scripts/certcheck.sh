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
subscription_id=$1
resource_group=$2
front_door_name=$3

# Function to check certificate expiration
check_certificate_expiration() {
    url=$1
    expiration_date=$(echo | openssl s_client -servername "${url}" -connect "${url}:443" 2>/dev/null | openssl x509 -noout -dates 2>/dev/null | grep "notAfter" | cut -d "=" -f 2)

    if [[ -n $expiration_date ]]; then
        expiration_timestamp=$($date_command -d "${expiration_date}" +%s)
        current_timestamp=$($date_command +%s)
        seconds_left=$((expiration_timestamp - current_timestamp))
        days_left=$((seconds_left / 86400))

        
        if [[ $days_left -le 70 ]]; then
             echo "> :red_circle: Certificate for (*${front_door_name}*) *${url}* expires in *${days_left}* days."
             has_results=true
        elif [[ $days_left -le 166 ]]; then
            echo "> :yellow_circle: Certificate for (*${front_door_name}*) *${url}* expires in *${days_left}* days."
        fi
    fi
}

# Azure CLI command to populate URL list
urls=$(az network front-door frontend-endpoint list --subscription "$subscription_id" --resource-group "$resource_group" --front-door-name "$front_door_name" --query "[].hostName" -o tsv)

# Check certificate expiration for each URL
has_results=false
for url in $urls; do
    check_certificate_expiration "${url}"
done

# Print header and results to output file if there are results
if [[ $has_results == true ]]; then
    printf "\n:cert: _*Expiring SSL Certificates*_\n\n" >> slack-message.txt
    for url in $urls; do
        check_certificate_expiration "${url}" >> slack-message.txt
    done
fi