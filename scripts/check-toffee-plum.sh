#!/usr/bin/env bash

function add_environments() {
    if [[ "$1" == "Toffee" ]]; then
        ENVIRONMENTS=("Sandbox" "Test" "ITHC" "Demo" "Staging" "Prod")
    fi
    if [[ "$1" == "Plum" ]]; then
        ENVIRONMENTS=("Sandbox" "Perftest" "ITHC" "Demo" "AAT" "Prod")
    fi
}

function status_code() {
    if [ $ENV == "Prod" ]; then
        url="https://$1.platform.hmcts.net"
        statuscode=$(curl -s -o /dev/null -w "%{http_code}" $url)
    elif [ $ENV != "Prod" ]; then
        url="https://$1.$ENV.platform.hmcts.net"
        statuscode=$(curl -s -o /dev/null -w "%{http_code}" $url)
    fi
}

function failure_check() {
    if [[ $statuscode != 200 ]] && [[ $1 == "Toffee" ]]; then
        failures_exist_toffee="true"
        printf "\n>:red_circle:  <$url| $ENV> is unhealthy" >>slack-message.txt
    elif [[ $statuscode != 200 ]] && [[ $1 == "Plum" ]]; then
        failures_exist_plum="true"
        printf "\n>:red_circle:  <$url| $ENV> is unhealthy" >>slack-message.txt
    fi
}

function uptime() {
    for ENV in ${ENVIRONMENTS[@]}; do
        status_code $1
        failure_check $1
    done
}

function do_failures_exist() {
    # if [[ $1 = "Toffee" ]]; then
    #     if [[ $failures_exist_toffee != "true" ]]; then
    #         printf "\n>:green_circle:  All environments in $1 are healthy" >>slack-message.txt
    #     fi
    # elif [[ $1 = "Plum" ]]; then
    #     if [[ $failures_exist_plum != "true" ]]; then
    #         printf "\n>:green_circle:  All environments in $1 are healthy" >>slack-message.txt
    #     fi
    # fi
    
    if [[ $failures_exist_plum != "true" && $failures_exist_toffee != "true" ]]; then
        printf "\n>:green_circle:  All environments are healthy" >>slack-message.txt
    fi
}

printf "\n:detective-pikachu: _*Check Toffee/Plum Status*_ \n" >>slack-message.txt

APPS=("Toffee" "Plum")
for APP in ${APPS[@]}; do
    printf "\n*$APP Status:*" >>slack-message.txt
    add_environments $APP
    uptime $APP
    do_failures_exist $APP
done
