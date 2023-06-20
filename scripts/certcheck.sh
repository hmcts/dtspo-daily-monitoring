#!/bin/bash
az extension add --name front-door --yes
# Check platform
platform=$(uname)

# Function to install missing packages using brew (macOS) or apt-get (Linux)
install_missing_packages() {
    if [[ $platform == "Darwin" ]]; then
        brew install "$1"
    elif [[ $platform == "Linux" ]]; then
        sudo apt-get install -y "$1"
    fi
}

# Check and install missing packages
if [[ $platform == "Darwin" ]]; then
    packages=("gawk" "gsed" "yj" "jq")
elif [[ $platform == "Linux" ]]; then
    packages=("awk" "sed" "yj" "jq")
fi

for package in "${packages[@]}"; do
    installed=$(which "$package" | grep -o "$package" > /dev/null && echo 0 || echo 1)
    if [[ $installed == 1 ]]; then
        echo "$package is missing! Installing it..."
        install_missing_packages "$package"
    fi
done

# Azure CLI command to populate URL list
subscription_id=$1
resource_group=$2
front_door_name=$3

# Function to check certificate expiration
check_certificate_expiration() {
    url=$1
    expiration_date=$(echo | openssl s_client -servername "${url}" -connect "${url}:443" 2>/dev/null | openssl x509 -noout -dates 2>/dev/null | grep "notAfter" | cut -d "=" -f 2)

    if [[ -n $expiration_date ]]; then
        expiration_timestamp=$(date -d "${expiration_date}" +%s)
        current_timestamp=$(date +%s)
        seconds_left=$((expiration_timestamp - current_timestamp))
        days_left=$((seconds_left / 86400))

        if [[ $days_left -le 100 ]]; then
            echo "Certificate for *${url}* expires in *${days_left}* days."
            has_results=true
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
    printf ":cert: Expiring SSL Certificates\n\n" > slack-message.txt
    for url in $urls; do
        check_certificate_expiration "${url}" >> slack-message.txt
    done
fi