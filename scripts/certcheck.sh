# Azure CLI command to populate URL list
subscription_id=$1
resource_group=$2
front_door_name=$3

# Function to check certificate expiration
check_certificate_expiration() {
    url=$1
    expiration_date=$(echo | openssl s_client -servername "${url}" -connect "${url}:443" 2>/dev/null | openssl x509 -noout -dates 2>/dev/null | grep "notAfter" | cut -d "=" -f 2)

    if [[ -n $expiration_date ]]; then
        expiration_timestamp=$(gdate -d "${expiration_date}" +%s)
        current_timestamp=$(gdate +%s)
        seconds_left=$((expiration_timestamp - current_timestamp))
        days_left=$((seconds_left / 86400))

        if [[ $days_left -le 100 ]]; then
            echo "Certificate for ${url} expires in ${days_left} days."
            printf "\n:cert: <https://portal.azure.com/#@HMCTS.NET/resource/subscriptions/8cbc6f36-7c56-4963-9d36-739db5d00b27/resourceGroups/lz-prod-rg/providers/Microsoft.Network/frontdoors/hmcts-prod/config_*Expiry Certificate*_> \n\n" >> slack-message.txt
            printf "\n:yellow_circle: Certificates are Expiring in $days_left days \n\n" >> slack-message.txt
            exit 0
        fi
    else
        echo "Unable to check the certificate for ${url}."
        printf "\n:cert: <https://portal.azure.com/#@HMCTS.NET/resource/subscriptions/8cbc6f36-7c56-4963-9d36-739db5d00b27/resourceGroups/lz-prod-rg/providers/Microsoft.Network/frontdoors/hmcts-prod/config_*Expiry Certificate*_> \n\n" >> slack-message.txt
        printf "\n:yellow_circle: Unable to check the certificate for ${url} \n\n" >> slack-message.txt
    fi
}

urls=$(az network front-door frontend-endpoint list --subscription "$subscription_id" --resource-group "$resource_group" --front-door-name "$front_door_name" --query "[].hostName" -o tsv)

# Check certificate expiration for each URL
for url in $urls; do
    check_certificate_expiration "${url}"
done