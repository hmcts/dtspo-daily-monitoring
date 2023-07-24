#!/usr/bin/env bash

function add_environments() {
        if [[ "$APP" == "toffee" ]]; then
        ENVIRONMENTS=("sandbox" "test" "ithc" "demo" "staging" "prod")
        fi
        if [[ "$APP" == "plum" ]]; then
        ENVIRONMENTS=("sandbox" "perftest" "ithc" "demo" "aat" "prod")
        fi
}

function status_code() {
    if [ $ENV == "prod" ]; then
        statuscode="https://$APP.platform.hmcts.net"
    elif [ $ENV != "prod" ]; then
        statuscode="https://$APP.$ENV.platform.hmcts.net"
    fi

    echo $statuscode
}

function slack_message() {
    if [[ "$ENV" == "demo" && $statuscode -eq 302 ]]; then
        printf "\n>:green_circle: https://$APP.$ENV.platform.hmcts.net" >> slack-message.txt
    elif [[ "$ENV" == "prod" && $statuscode -eq 200 ]]; then
        printf "\n>:green_circle: https://$APP.platform.hmcts.net" >> slack-message.txt
    elif [[ "$ENV" == "prod" && $statuscode -ne 200 ]]; then
        printf "\n>:green_circle: https://$APP.platform.hmcts.net" >> slack-message.txt
    elif [[ $statuscode -eq 200 ]]; then
        printf "\n>:green_circle: https://$APP.$ENV.platform.hmcts.net" >> slack-message.txt
    else
        printf "\n>:red_circle: https://$APP.$ENV.platform.hmcts.net" >> slack-message.txt
    fi
}

function uptime() {
for ENV in ${ENVIRONMENTS[@]}; do
    status_code
    # slack_message
done
}

printf "\ntoffee status:" >> slack-message.txt

### test toffee
APP="toffee"
add_environments
uptime

printf "\nplum status:" >> slack-message.txt

### test plum
APP="plum"
add_environments
uptime