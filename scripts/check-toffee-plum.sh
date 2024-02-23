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
        status_code $1 # passing name
        failure_check $1 # passing name 
    done
}

function do_failures_exist() {
    if [[ $1 = "Toffee" ]]; then
        if [[ $failures_exist_toffee != "true" ]]; then
            Toffee[no_fail_msg]+="\n>:green_circle:  All environments in $1 are healthy" 
        fi

    elif [[ $1 = "Plum" ]]; then
        if [[ $failures_exist_plum != "true" ]]; then
            Plum[no_fail_msg]+="\n>:green_circle:  All environments in $1 are healthy"
        fi
    fi
}

function check_status() {
    # printf "\n*$1 Status:*" >>slack-message.txt
    add_environments $1
    uptime $1
    do_failures_exist $1

    # if [[ -n "${Toffee[no_fail_msg]}" ]] && [[ -n "${Plum[no_fail_msg]}" ]]; then
    #     printf "\n>:green_circle:  All environments are healthy" >>slack-message.txt
    # fi
}

function format_status() {

    # first check that no failures have occured
    if [[ "${Toffee[no_fail_msg]}" ]] && [[ -n "${Plum[no_fail_msg]}" ]]; then
        printf "\n>:green_circle:  All environments are healthy" >>slack-message.txt

    # if failure occurs print failure msg for each toffee or plum
    elif [[ $1 == "Toffee" ]]; then
        printf "\n*$1 Status:*" >>slack-message.txt

        # if toffee has no failures
        if [[ -n "${Toffee[no_fail_msg]}" ]]; then
            printf "s%" "${Toffee[no_fail_msg]}" >>slack-message.txt
        else
            printf "s%" "${Toffee[failure_msg]}" >>slack-message.txt
        fi
    fi

    # elif [[ $1 == "Plum" ]]; then
    #     printf "\n*$1 Status:*" >>slack-message.txt
    #     printf "s%\n" "${Plum[no_fail_msg]}" >>slack-message.txt
    # fi
}

# hold any failure or success messages 
declare -A Toffee=( 
    [failure_msg]=
    [no_fail_msg]=
)
declare -A Plum=( 
    [failure_msg]=
    [no_fail_msg]=
)

# function runner
APPS=("Toffee" "Plum")
printf "\n:detective-pikachu: _*Check Toffee/Plum Status*_ \n" >>slack-message.txt

# Check app status first
for APP in ${APPS[@]}; do
    check_status $APP
done

# format output
for APP in ${APPS[@]}; do
    format_status $APP
done
