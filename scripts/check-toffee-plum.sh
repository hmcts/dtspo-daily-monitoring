#!/usr/bin/env bash

function add_environments() {
        if [[ "$APP" == "toffee" ]]; then
        ENVIRONMENTS=("sbox" "test" "ithc" "demo" "staging" "prod")
        elif [[ "$APP" == "plum" ]]; then
        ENVIRONMENTS=("sbox" "perftest" "ithc" "demo" "aat" "prod")
        fi
}

function logic() {
    statuscode=$(curl --max-time 30 --retry 20 --retry-delay 15 -s -o /dev/null -w "%{http_code}"  https://$APP.$ENV.platform.hmcts.net)
    echo $statuscode
    # if [[ "$ENVIRONMENT" == "demo" && $statuscode -eq 302 ]]; then
    #     printf "\n>:green_circle: https://$APP.$ENV.platform.hmcts.net" >> slack-message.txt
    # elif [[ $statuscode -eq 200 ]]; then
    #     printf "\n>:green_circle: https://$APP.$ENV.platform.hmcts.net" >> slack-message.txt
    # else
    #     printf "\n>:red_circle: https://$APP.$ENV.platform.hmcts.net" >> slack-message.txt
    # fi
}

function uptime() {
for env in ${ENVIRONMENTS[@]}; do
  logic
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