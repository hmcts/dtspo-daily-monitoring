#!/usr/bin/env bash

set -o pipefail

client_id=$1 # Client ID (appID) as first argument

base64pem=$2 #take pem as string as second argument
#decode it back to private key
pem=$(echo "$base64pem" | base64 --decode )

now=$(date +%s)
iat=$((${now} - 60)) # Issues 60 seconds in the past
#exp=$((${now} + 3600))
exp=$((${now} + 1)) 

#encodes in url safe base64 
b64enc() { openssl base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n'; }

header_json='{
    "typ":"JWT",
    "alg":"RS256"
}'
# Header encode
header=$( echo -n "${header_json}" | b64enc )

payload_json="{
    \"iat\":${iat},
    \"exp\":${exp},
    \"iss\":\"${client_id}\"
}"
# Payload encode
payload=$( echo -n "${payload_json}" | b64enc )

# Signature
# Write the private key to a temporary file
header_payload="${header}"."${payload}"

temp_key_file=$(mktemp)
echo -n "${pem}" > "$temp_key_file"
temp_header_payload_file=$(mktemp)
echo -n "${header_payload}" > "$temp_header_payload_file"

signature=$(
    openssl dgst -sha256 -sign $temp_key_file \
    "$temp_header_payload_file" | b64enc
)

# Create JWT
JWT="${header_payload}"."${signature}"
echo "##vso[task.setvariable variable=jwt;issecret=true]$JWT"

# Clean up the temporary files
rm -f "$temp_key_file" "$temp_header_payload_file"