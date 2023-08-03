#!/usr/bin/env bash

function add_environments() {
        if [[ "$1" == "toffee" ]]; then
        ENVIRONMENTS=("sandbox" "test" "ithc" "demo" "staging" "prod")
        fi
        if [[ "$1" == "plum" ]]; then
        ENVIRONMENTS=("sandbox" "perftest" "ithc" "demo" "aat" "prod")
        fi
}

function status_code() {
    if [ $ENV == "prod" ]; then
        url="https://$1.platform.hmcts.net"
        statuscode=$(curl -s -o /dev/null -w "%{http_code}" $url)
    elif [ $ENV != "prod" ]; then
        url="https://$1.$ENV.platform.hmcts.net"
        statuscode=$(curl -s -o /dev/null -w "%{http_code}" $url)
    fi
}

function failure_check() {
    if [[ $statuscode != 200 ]] && [[ $1 == "toffee" ]]; then
        failures_exist_toffee="true"
        printf "\n>:red_circle:  <$url| $ENV>" >> slack-message.txt
    elif [[ $statuscode != 200 ]] && [[ $1 == "plum" ]]; then
        failures_exist_plum="true"
        printf "\n>:red_circle:  <$url| $ENV>" >> slack-message.txt
    fi
}

function uptime() {
for ENV in ${ENVIRONMENTS[@]}; do
    status_code $1
    failure_check $1
done
}

function do_failures_exist() {
    if [[ $1 = "toffee" ]]; then
        if [[ $failures_exist_toffee != "true" ]]; then
            printf "\n>:green_circle: EVERYTHING WORKED in toffee" >> slack-message.txt
        fi
    elif [[ $1 = "plum" ]]; then
        if [[ $failures_exist_plum != "true" ]]; then
            printf "\n>:green_circle: EVERYTHING WORKED in plum" >> slack-message.txt
        fi
    fi
}

printf "\n:detective-pikachu: _*Check Toffee/Plum Status*_ \n" >> slack-message.txt

APPS=("toffee" "plum")
    for APP in ${APPS[@]}; do
    printf "\n*$APP Status:*" >> slack-message.txt

    add_environments $APP
    uptime $APP
    do_failures_exist $APP
done