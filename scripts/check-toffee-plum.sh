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
        url="https://$APP.platform.hmcts.net"
        statuscode=$(curl -s -o /dev/null -w "%{http_code}" $url)
    elif [ $ENV != "prod" ]; then
        url="https://$APP.$ENV.platform.hmcts.net"
        statuscode=$(curl -s -o /dev/null -w "%{http_code}" $url)
    fi

    echo $url
    echo $statuscode
}

function failure_check() {
    if [[ $statuscode -ne 200 ]]; then
        failed=true
    fi
}

function slack_message() {
    if [[ $failed -eq false ]]; then
        printf "\n>:green_circle:  All $APP environments are accessible" >> slack-message.txt  
        # printf "\n>:red_circle:  <$url| $ENV>" >> slack-message.txt  
    else
        printf "\n>:green_circle:  <$url| $ENV>" >> slack-message.txt
    fi
}

function uptime() {
for ENV in ${ENVIRONMENTS[@]}; do
    status_code
    failure_check
done
}

printf "\n:detective-pikachu: _*Check Toffee/Plum Status*_ \n">> slack-message.txt
printf "\n*Toffee Status:*" >> slack-message.txt

### test toffee
APP="toffee"
add_environments
uptime
slack_message

printf "\n*Plum Status:*" >> slack-message.txt

### test plum
failed=false
APP="plum"
add_environments
uptime
slack_message