#!/usr/bin/env bash

ENVIRONMENTS=("sbox" "ithc" "demo" "prod")

function add_environments() {
        if [[ "$APP" == "toffee" ]]; then
        ENVIRONMENTS+=(dev, test, staging)
        elif [[ "$APP" == "plum" ]]; then
        ENVIRONMENTS+=(preview, perftest, aat)
        fi
}

function logic() {
    statuscode=$(curl --max-time 30 --retry 20 --retry-delay 15 -s -o /dev/null -w "%{http_code}"  https://$APP.$ENV.platform.hmcts.net)

    if [[ "$ENVIRONMENT" == "demo" && $statuscode -eq 302 ]]; then
        printf "\n>:green_circle: https://$APP.$ENV.platform.hmcts.net" >> slack-message.txt
    elif [[ $statuscode -eq 200 ]]; then
        printf "\n>:green_circle: https://$APP.$ENV.platform.hmcts.net" >> slack-message.txt
    else
        printf "\n>:red_circle: https://$APP.$ENV.platform.hmcts.net" >> slack-message.txt
    fi
}

function uptime() {
for env in ${ENVIRONMENTS[@]}; do
  echo $env
done
}

### test toffee
APP="toffee"
add_environments
uptime

### test plum
APP="plum"
add_environments
uptime