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
        if [[ $statuscode != 200 ]] && [[ $1 == "Toffee" ]] && [[ $failures_exist_toffee == "true" ]]; then
            printf "\n>:red_circle:  <$url| $ENV> is unhealthy" >>slack-message.txt
        fi
        failures_exist_toffee="true"

    elif [[ $statuscode != 200 ]] && [[ $1 == "Plum" ]]; then
        if [[ $statuscode != 200 ]] && [[ $1 == "Plum" ]] && [[ $failures_exist_plum == "true" ]]; then
            printf "\n>:red_circle:  <$url| $ENV> is unhealthy" >>slack-message.txt
        fi
        failures_exist_plum="true"
    fi
}

function uptime() {
    for ENV in ${ENVIRONMENTS[@]}; do
        status_code $1
        failure_check $1
    done
}

function do_failures_exist() {
    if [[ $1 = "Toffee" ]]; then
        if [[ $failures_exist_toffee != "true" ]]; then
            printf "\n>:green_circle:  All environments in $1 are healthy" >>slack-message.txt
        fi

    elif [[ $1 = "Plum" ]]; then
        if [[ $failures_exist_plum != "true" ]]; then
            printf "\n>:green_circle:  All environments in $1 are healthy" >>slack-message.txt
        fi
    fi
}

APPS=("Toffee" "Plum")

printf "\n:detective-pikachu: _*Check Toffee/Plum Status*_ \n" >>slack-message.txt

# Check app status first before output
for APP in ${APPS[@]}; do
    add_environments $APP
    uptime $APP
done

# format output
if [[ $failures_exist_toffee != "true" && $failures_exist_plum != "true" ]]; then
    # print if no failure exist
    printf "\n>:green_circle:  All environments are healthy" >>slack-message.txt
else
    # print if failure exist, $1 data does not persist need to re run logic
    for APP in ${APPS[@]}; do
        printf "\n*$APP Status:*" >>slack-message.txt
        add_environments $APP
        uptime $APP
        do_failures_exist $APP
    done
fi

# ------------

Object() {
    kind="application"
    self="appToffee"

    name=$APP
    ENVIRONMENTS=""
    failed_url=""
    status_code=""
    failed_url=""
    failure_txt_output=""
}

declare -A apps=( [app1]=Toffee [app2]=Plum )



printf "\nObject Toffee: ${apps[app1]}" >>slack-message.txt


# Object() {
#     name="Toffee"
#     ENVIRONMENTS= add_environments "Toffee"
#     failed_url=""
#     statuscode=""
#     failure="false"
#     failure_txt_output=""
# }