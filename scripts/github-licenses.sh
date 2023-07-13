TOKEN=$1

RESULT=$(curl -L -H "Accept: application/vnd.github+json" -H "Authorization: Bearer ${TOKEN}" -H "X-GitHub-Api-Version: 2022-11-28" \
  https://api.github.com/enterprises/hmcts/consumed-licenses)
CONSUMED_LICENSES=$(jq -r .total_seats_consumed <<< "${RESULT}")
TOTAL_LICENSES=$(jq -r .total_seats_purchased <<< "${RESULT}")
 
LICENSES_LEFT=$((TOTAL_LICENSES-CONSUMED_LICENSES))

LICENSE_STATUS=":red_circle:"
if (( "$LICENSES_LEFT" >= 25 )); then
  LICENSE_STATUS=":green_circle:"
elif ((  "$LICENSES_LEFT" >= 10 )); then
  LICENSE_STATUS=":yellow_circle:"
fi

printf "\n:github: <https://github.com/orgs/hmcts/people|_*GitHub License Status*_> \n\n" >> slackmessage.txt
printf "> %s *%s* out of *%s* licenses left \n" "$LICENSE_STATUS" "$LICENSES_LEFT" "$TOTAL_LICENSES" >> slackmessage.txt