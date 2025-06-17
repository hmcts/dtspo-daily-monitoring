#!/bin/bash

set -euo pipefail

# Source central functions script
source scripts/common-functions.sh

sendgridApiKey=
emailTo=
emailFrom=
testMode=false

usage(){
>&2 cat << EOF
------------------------------------------------
Script to check DLQ case type counts
------------------------------------------------
Usage: $0
    [ -k | --sendgridApiKey ]
    [ -t | --emailTo ]
    [ -f | --emailFrom ]
    [ --test | --testMode true/false default: false]
    [ -h | --help ]

Options:
    -k, --sendgridApiKey    SendGrid API key for sending emails
    -t, --emailTo          Comma-separated list of email addresses to send notifications to
    -f, --emailFrom        Email address to send notifications from (MUST be verified in SendGrid)
    --test, --testMode     Run in test mode (true/false, no emails sent, default: false)
    -h, --help             Show this help message

IMPORTANT: The --emailFrom address must be verified in your SendGrid account.
Go to: https://app.sendgrid.com/settings/sender_auth to verify your sender address.

Examples:
    # Test mode (no emails sent)
    $0 --test

    # Production mode (emails will be sent - requires verified sender)
    # Single recipient
    $0 -k "SG.xyz..." -t "admin@example.com" -f "verified-sender@your-domain.com"

    # Multiple recipients
    $0 -k "SG.xyz..." -t "admin1@example.com,admin2@example.com,admin3@example.com" -f "verified-sender@your-domain.com"
EOF
exit 1
}

args=$(getopt -a -o k:t:f:h: --long sendgridApiKey:,emailTo:,emailFrom:,test:,testMode:,help -- "$@")
if [[ $? -gt 0 ]]; then
    usage
fi

eval set -- ${args}
while :
do
    case $1 in
        -h | --help)              usage                    ; shift   ;;
        -k | --sendgridApiKey)    sendgridApiKey=$2        ; shift 2 ;;
        -t | --emailTo)           emailTo=$2               ; shift 2 ;;
        -f | --emailFrom)         emailFrom=$2             ; shift 2 ;;
        --test | --testMode)
            # Convert to lowercase for comparison
            testValue=$(echo "$2" | tr '[:upper:]' '[:lower:]')
            if [[ "$testValue" == "true" || "$testValue" == "false" ]]; then
                testMode=$testValue
            else
                echo "Error: test mode value must be 'true' or 'false'" >&2
                exit 1
            fi
            shift 2 ;;
        # -- means the end of the arguments; drop this, and break out of the while loop
        --) shift; break ;;
        *) >&2 echo Unsupported option: $1
            usage ;;
    esac
done

# Check required parameters only if not in test mode
if [[ "$testMode" == "false" ]]; then
    if [[ -z "$sendgridApiKey" || -z "$emailTo" || -z "$emailFrom" ]]; then
        {
            echo "------------------------"
            echo 'Please supply all of: '
            echo '- SendGrid API key'
            echo '- Email to address'
            echo '- Email from address'
            echo ''
            echo 'OR use --test flag to run in test mode'
            echo "------------------------"
        } >&2
        exit 1
    fi
else
    echo "🧪 Running in TEST MODE - no emails will be sent"
    echo "=================================================="
fi

# Configuring the script
ELASTICSEARCH_HOST="10.96.85.7:9200"
OUTPUT=""
EMAIL_BODY=""

# Array of case type IDs
CASE_TYPE_LIST=(
    "GrantOfRepresentation"
    "Benefit"
    "MoneyClaimCase"
    "DIVORCE"
    "NFD"
    "Watford"
    "PROBATE_ExceptionRecord"
    "SSCS_ExceptionRecord"
    "FinancialRemedyMVP2"
    "Manchester"
    "CIVIL"
    "Scotland"
    "Asylum"
    "LondonCentral"
    "MidlandsWest"
    "Caveat"
    "CARE_SUPERVISION_EPO"
    "Leeds"
    "LondonEast"
    "FinancialRemedyContested"
    "LondonSouth"
    "Bristol"
    "DIVORCE_ExceptionRecord"
    "FINREM_ExceptionRecord"
    "HearingRecordings"
    "WillLodgement"
    "MidlandsEast"
    "StandingSearch"
    "Wales"
    "Newcastle"
    "DIVORCE_BulkAction"
    "CMC_ExceptionRecord"
    "NFD_ExceptionRecord"
    "Watford_Multiple"
    "Manchester_Multiple"
    "Scotland_Multiple"
    "NO_FAULT_DIVORCE_BulkAction"
    "LondonCentral_Multiple"
    "ET_EnglandWales"
    "PUBLICLAW_ExceptionRecord"
    "LondonSouth_Multiple"
    "Leeds_Multiple"
    "MidlandsWest_Multiple"
    "MidlandsEast_Multiple"
    "Bristol_Multiple"
    "LondonEast_Multiple"
    "ET_Scotland"
    "PRLAPPS"
    "Bail"
    "Wales_Multiple"
    "Newcastle_Multiple"
    "A58"
    "Shared_Storage_DRAFTType"
    "AAT"
    "Scotland_Listings"
    "ET_EnglandWales_Listings"
    "LondonSouth_Listings"
    "LondonCentral_Listings"
    "Bristol_Listings"
    "Leeds_Listings"
    "Watford_Listings"
    "Manchester_Listings"
    "MidlandsWest_Listings"
    "MidlandsEast_Listings"
    "Wales_Listings"
    "Newcastle_Listings"
    "LondonEast_Listings"
    "ET_Scotland_Listings"
)

# Function to send email via SendGrid
sendEmailNotification() {
    local api_key=$1
    local to_email=$2
    local from_email=$3
    local subject=$4
    local content=$5
    local status_emoji=$6

    # Convert comma-separated email list to JSON array
    local to_emails_json=$(echo "$to_email" | tr ',' '\n' | jq -R -s 'split("\n")[:-1] | map({"email": .})')

    # Create JSON payload for SendGrid
    local email_payload=$(jq -n \
        --argjson to_emails "$to_emails_json" \
        --arg from_email "$from_email" \
        --arg subject "$subject" \
        --arg content "$content" \
        '{
            "personalizations": [
                {
                    "to": $to_emails
                }
            ],
            "from": {
                "email": $from_email
            },
            "subject": $subject,
            "content": [
                {
                    "type": "text/plain",
                    "value": $content
                }
            ]
        }')

    # Send email via SendGrid API
    local response=$(curl -s -w "\n%{http_code}" -X POST \
        https://api.sendgrid.com/v3/mail/send \
        -H "Authorization: Bearer $api_key" \
        -H "Content-Type: application/json" \
        -d "$email_payload")

    local http_code=$(echo "$response" | tail -n1)
    local response_body=$(echo "$response" | head -n -1)

    if [[ "$http_code" -eq 202 ]]; then
        echo "✅ Email sent successfully"
    else
        echo "❌ Email sending failed (HTTP $http_code)"
        echo "Response: $response_body"
        if [[ "$response_body" == *"does not match a verified Sender Identity"* ]]; then
            echo ""
            echo "🚨 SENDER VERIFICATION ERROR:"
            echo "The email address '$from_email' is not verified in SendGrid."
            echo "Please verify it at: https://app.sendgrid.com/settings/sender_auth"
        fi
        return 1
    fi
}

# Process each case type from the array
for case_type_id in "${CASE_TYPE_LIST[@]}"; do
    if [[ -n "$case_type_id" ]]; then
        # Get the DLQ count for the case type
        dlq_count_breakdown=$(curl -s -X GET "$ELASTICSEARCH_HOST/.logstash_dead_letter/_count" \
            -H 'Content-Type: application/json' \
            -d "{\"query\": {\"match_phrase\": {\"failed_case\": \"\\\"case_type_id\\\":\\\"$case_type_id\\\"\"}}}")

        count=$(echo "$dlq_count_breakdown" | grep -o '"count":[0-9]*' | cut -d':' -f2)

        # Append the result to the output variable if count > 0
        if [[ -n "$count" && "$count" -gt 0 ]]; then
            # Parse JSON response for prettier formatting
            total_shards=$(echo "$dlq_count_breakdown" | jq -r '._shards.total // "N/A"')
            successful_shards=$(echo "$dlq_count_breakdown" | jq -r '._shards.successful // "N/A"')
            skipped_shards=$(echo "$dlq_count_breakdown" | jq -r '._shards.skipped // "N/A"')
            failed_shards=$(echo "$dlq_count_breakdown" | jq -r '._shards.failed // "N/A"')

            OUTPUT+=$(printf "\nCase Type ID: %-30s Count: %s" "$case_type_id" "$count")

            # Create prettier email content
            EMAIL_BODY+="Case Type ID: $case_type_id"$'\n'
            EMAIL_BODY+="Total Count: $count"$'\n'
            EMAIL_BODY+="Shards - Total: $total_shards, Successful: $successful_shards, Skipped: $skipped_shards, Failed: $failed_shards"$'\n'
            EMAIL_BODY+=""$'\n'  # Add blank line for readability

            echo "Found $count results for case type: $case_type_id"
        else
            echo "No results found for case type: $case_type_id"
        fi
    fi
done

# Determine status and prepare email content
STATUS="🔴"
EMAIL_SUBJECT="🔴 DLQ Case Type Count Alert"
if [[ -z "$OUTPUT" ]]; then
    STATUS="🟢"
    EMAIL_SUBJECT="🟢 DLQ Case Type Count - All Clear"
    EMAIL_BODY="All case types have zero DLQ counts."
fi

# Handle test mode vs production mode
if [[ "$testMode" == "true" ]]; then
    # TEST MODE: Show what would happen without actually sending emails
    echo ""
    if [[ "$STATUS" == "🔴" ]]; then
        echo "⚠️  Issues found!"
    else
        echo "✅ No issues found - all DLQ counts are zero"
    fi

    echo ""
    echo "📧 EMAIL PREVIEW"
    echo "═══════════════════════════════════════"
    echo "To: ${emailTo/,/, } (if provided)"
    echo "From: $emailFrom (if provided)"
    echo "Subject: $EMAIL_SUBJECT"
    echo "───────────────────────────────────────"
    echo "Content:"
    echo "$EMAIL_BODY"
    echo "═══════════════════════════════════════"

    if [[ "$STATUS" == "🟢" ]]; then
        echo "Note: Success emails are currently commented out in production mode"
    fi

    echo ""
    echo "📊 FINAL SUMMARY"
    echo "═══════════════════════════════════════"
    if [[ -n "$OUTPUT" ]]; then
        echo "DLQ Case Type Counts:"
        echo "$OUTPUT"
        echo ""
    else
        echo "✅ All Clear: No DLQ counts found"
        echo "(all case types returned 0 results)"
    fi
    echo "═══════════════════════════════════════"

    echo ""
    echo "🧪 TEST MODE SUMMARY:"
    echo "===================="
    echo "- Script execution: ✅ Complete"
    echo "- Email sending: ❌ Disabled (test mode)"
    echo "- Elasticsearch queries: ✅ Executed"
    echo ""
    echo "To run with email sending enabled, use:"
    echo "$0 -k \"YOUR_SENDGRID_API_KEY\" -t \"recipient@example.com\" -f \"sender@example.com\""

else
    # PRODUCTION MODE: Actually send emails when needed
    if [[ "$STATUS" == "🔴" ]]; then
        echo "Issues found, sending email notification..."
        sendEmailNotification "$sendgridApiKey" "$emailTo" "$emailFrom" "$EMAIL_SUBJECT" "$EMAIL_BODY" "$STATUS"
        echo "Email sent with DLQ count details"
    else
        echo "✅ No issues found - all DLQ counts are zero"
        # Uncomment the line below if you want to send success emails too
        # sendEmailNotification "$sendgridApiKey" "$emailTo" "$emailFrom" "$EMAIL_SUBJECT" "$EMAIL_BODY" "$STATUS"
    fi

    echo ""
    echo "📊 FINAL SUMMARY"
    echo "═══════════════════════════════════════"
    if [[ -n "$OUTPUT" ]]; then
        echo "DLQ Case Type Counts:"
        echo "$OUTPUT"
        echo ""
    else
        echo "✅ All Clear: No DLQ counts found"
        echo "(all case types returned 0 results)"
    fi
    echo "═══════════════════════════════════════"
fi
