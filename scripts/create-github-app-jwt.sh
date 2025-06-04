#!/usr/bin/env bash
thisdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -o pipefail

#input
client_id=$1 # Client ID (appID) as first argument
base64pem=$2 #take pem as string as second argument

# logging
log_file="$thisdir/create-github-app-jwt.log"
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$log_file"
}

#decode it back to private key
temp_cert_file=$(mktemp)
echo $base64pem | base64 --decode> "$temp_cert_file"
log "temp_cert_file"
log $(cat $temp_cert_file)

#encodes in url safe base64 
b64enc() { openssl base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n'; }

#header
now=$(date +%s)
iat=$((${now} - 60)) # Issues 60 seconds in the past
exp=$((${now} + 3600))

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

#avoiding process substitution
temp_header_payload_file=$(mktemp)
echo -n "${header_payload}" > "$temp_header_payload_file"
log "temp_header_payload_file"
log $(cat $temp_header_payload_file)

signature=$(
    openssl dgst -sha256 -sign $temp_cert_file \
    $temp_header_payload_file | b64enc
)
log "signature"
log $signature

# Create JWT
JWT="${header_payload}"."${signature}"
echo "##vso[task.setvariable variable=jwt;issecret=true]$JWT"

log "JWT"
log $JWT

# Clean up the temporary files
rm -f "$temp_key_file" "$temp_header_payload_file"