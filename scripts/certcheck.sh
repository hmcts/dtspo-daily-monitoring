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
            echo "Certificate for *${url}* expires in *${days_left}* days."
            has_results=true
        fi
    fi
}

# Azure CLI command to populate URL list
urls=$(az network front-door frontend-endpoint list --subscription 8cbc6f36-7c56-4963-9d36-739db5d00b27 --resource-group lz-prod-rg --front-door-name hmcts-prod --query "[].hostName" -o tsv)

# Check certificate expiration for each URL
has_results=false
for url in $urls; do
    check_certificate_expiration "${url}"
done

# Print header and results to output file if there are results
if [[ $has_results == true ]]; then
    printf ":cert: Expiring SSL Certificates\n\n" > slack-message.txt
    for url in $urls; do
        check_certificate_expiration "${url}" >> slack-message.txt
    done
fi