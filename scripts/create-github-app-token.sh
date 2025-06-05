#!/usr/bin/env bash
#
# Generates Github App access token $JWT and 'installation token' for "hmcts-daily-checks"
# Github App. Allowing auth via Github App auth rather than PAT tokens
#
# Requires: GH App private key added as a secure file to AzDO Library
#           GH App clientID
#           Permissions granted to the GHApp, app installed
#
# The following steps need adding to azure-pipelines.yaml after keyvault step:

        # # Pull private key to Create token
        # - task: DownloadSecureFile@1
        #   name: pemFile
        #   inputs:
        #     secureFile: 'hmcts-daily-checks-private-key.pem'
        
        # # pass securefiles private key to script
        # - task: Bash@3
        #   displayName: 'create GHApps access token (itoken) from private key'
        #   inputs:
        #     targetType: filePath
        #     filePath: scripts/create-github-app-token.sh
        #     arguments: $(appID) $(pemFile.secureFilePath)      

        # # instances of $(dtspo-daily-checks-github-fine-grained-token) 
        # # to be replaced with $(itoken)

thisdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -o pipefail

#input
client_id=$1            # Client ID (appID) as first argument
pem=$( cat $2 )         # file path of the private key as second argument

now=$(date +%s)
iat=$((${now} - 60))    # Issues 60 seconds in the past
exp=$((${now} + 599))   # Expires 10 minutes in the future 

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

# 69331259 is the app's install ID for hmcts/dtspo-daily-monitoring
response=$(curl -s -X POST -H "Authorization: Bearer $JWT" \
            -H "Accept: application/vnd.github+json" \
            https://api.github.com/app/installations/69331259/access_tokens)
# return 'installation' token
itoken=$(echo "$response" | jq -r '.token')
echo "##vso[task.setvariable variable=itoken;issecret=true]$itoken"