TOKEN=$1
set -ex

RESULT=$(curl -X GET https://app.launchdarkly.com/api/v2/members -H "Authorization: ${TOKEN}")
CONSUMED_LICENSES=$(jq -r .totalCount <<< "${RESULT}")
TOTAL_LICENSES=150 #None of the public APIs seem to return the number of licenses we have.
 
LICENSES_LEFT=$((TOTAL_LICENSES-CONSUMED_LICENSES))

LICENSE_STATUS=":red_circle:"
if (( "$LICENSES_LEFT" >= 25 )); then
  LICENSE_STATUS=":green_circle:"
elif ((  "$LICENSES_LEFT" >= 10 )); then
  LICENSE_STATUS=":yellow_circle:"
fi

printf "\n:launchdarkly: <https://app.launchdarkly.com/settings/members|_*LaunchDarkly License Status*_> \n\n" >> slack-message.txt
printf "> %s *%s* out of *%s* licenses left \n" "$LICENSE_STATUS" "$LICENSES_LEFT" "$TOTAL_LICENSES" >> slack-message.txt