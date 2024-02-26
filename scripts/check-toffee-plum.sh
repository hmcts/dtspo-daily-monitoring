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
    if [[ $statuscode == 200 ]] && [[ $1 == "Toffee" ]]; then
        # if [[ $statuscode != 200 ]] && [[ $1 == "Toffee" ]] && [[ $failures_exist_toffee == "true" ]]; then
        # toffee_failure_msg="\n>:red_circle:  <$url| $ENV> is unhealthy"
        toffee_failure_msg="\n>:green_circle:  <$url| $ENV> is healthy"
        # fi
        failures_exist_toffee="true"


    elif [[ $statuscode != 200 ]] && [[ $1 == "Plum" ]]; then
        # if [[ $statuscode != 200 ]] && [[ $1 == "Plum" ]] && [[ $failures_exist_plum == "true" ]]; then
        plum_failure_msg="\n>:red_circle:  <$url| $ENV> is unhealthy"
        # fi
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
            toffee_no_failure_msg="\n>:green_circle:  All environments in $1 are healthy" 
        fi

    elif [[ $1 = "Plum" ]]; then
        if [[ $failures_exist_plum != "true" ]]; then
            plum_no_failure_msg="\n>:green_circle:  All environments in $1 are healthy"
        fi
    fi
}

function check_status() {
    add_environments $1
    uptime $1
    do_failures_exist $1
}

function format_status() {
    # first check that no failures have occured
    if [[ $failures_exist_toffee != "true" ]] && [[ $failures_exist_plum != "true" ]]; then
        printf "\n>:green_circle:  All environments are healthy" >>slack-message.txt

    # if failure occurs print failure msg for each toffee and plum
    else
        printf "\n*Toffee Status:*" >>slack-message.txt

        if [[ $failures_exist_toffee != "true" ]]; then
            for MSG in ${toffee_no_failure_msg[@]}; do
                printf '%s\n' "$MSG" >>slack-message.txt
            done
        else
            for MSG in ${toffee_failure_msg[@]}; do
                printf '%s\n' "$MSG" >>slack-message.txt
            done
        fi

        printf "\n*Plum Status:*" >>slack-message.txt

        if [[ $failures_exist_plum != "true" ]]; then
            printf '%s\n' "${plum_no_failure_msg[@]}" >>slack-message.txt
        else
            printf '%s\n' "${plum_failure_msg[@]}" >>slack-message.txt
        fi
    fi
}

# hold any failure or success messages 
toffee_failure_msg=()
toffee_no_failure_msg=()

plum_failure_msg=()
plum_no_failure_msg=()


APPS=("Toffee" "Plum")
printf "\n:detective-pikachu: _*Check Toffee/Plum Status*_ \n" >>slack-message.txt

# Check app status first
for APP in ${APPS[@]}; do
    check_status $APP
done

format_status

# check toffee
# 
# check plum 
# 
# format output