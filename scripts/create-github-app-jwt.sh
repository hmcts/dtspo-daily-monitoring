#!/usr/bin/env bash

set -o pipefail

client_id=$1 # Client ID (appID) as first argument

pem=$2 #take pem as string as second argument

now=$(date +%s)
iat=$((${now} - 60)) # Issues 60 seconds in the past
exp=$((${now} + 3600)) 

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
header_payload="${header}"."${payload}"
signature=$(
    openssl dgst -sha256 -sign <(echo -n "${pem}") \
    <(echo -n "${header_payload}") | b64enc
)

# Create JWT
JWT="${header_payload}"."${signature}"
echo "##vso[task.setvariable variable=jwt;issecret=true]$JWT"