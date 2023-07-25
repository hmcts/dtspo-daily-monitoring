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
        url="http://$APP.platform.hmcts.net"
        statuscode=$(curl --max-time 20 --retry 3 -s -o /dev/null -w "%{http_code}" $url; echo "Exit code: $?")
    elif [ $ENV != "prod" ]; then
        url="http://$APP.$ENV.platform.hmcts.net"
        statuscode=$(curl --max-time 20 --retry 3 -s -o /dev/null -w "%{http_code}" $url; echo "Exit code: $?")
    fi

    echo $url
    echo $statuscode
}

function slack_message() {
    if [[ "$ENV" == "demo" && $statuscode -eq 302 ]]; then
        printf "\n>:green_circle: $url" >> slack-message.txt
    elif [[ $statuscode -eq 200 ]]; then
        printf "\n>:green_circle: $url" >> slack-message.txt
    else
        printf "\n>:red_circle: $url" >> slack-message.txt
    fi
}

function uptime() {
for ENV in ${ENVIRONMENTS[@]}; do
    status_code
    slack_message
done
}

printf "\n:detective-pikachu: _*Check Toffee/Plum Status*_ \n">> slack-message.txt
printf "\n*Toffee Status:*" >> slack-message.txt

### test toffee
APP="toffee"
add_environments
uptime

printf "\n*Plum Status:*" >> slack-message.txt

### test plum
APP="plum"
add_environments
uptime