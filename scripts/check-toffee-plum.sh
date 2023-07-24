#!/usr/bin/env bash

function add_environments() {
        if [[ "$APP" == "toffee" ]]; then
        ENVIRONMENTS=("sandbox" "test" "ithc" "demo" "staging" "prod")
        elif [[ "$APP" == "plum" ]]; then
        ENVIRONMENTS=("sandbox" "perftest" "ithc" "demo" "aat" "prod")
        fi
}

function logic() {
    if [ $ENV == "prod" ]; then
        statuscode=$(curl https://$APP.platform.hmcts.net)
    elif [ $ENV != "prod" ]; then
        statuscode=$(curl https://$APP.$ENV.platform.hmcts.net)
    fi

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
for ENV in ${ENVIRONMENTS[@]}; do
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