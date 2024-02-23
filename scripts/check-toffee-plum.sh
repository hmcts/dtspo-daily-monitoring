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
            Toffee[no_fail_msg]+="this is testing append on associated array"
        fi

    elif [[ $1 = "Plum" ]]; then
        if [[ $failures_exist_plum != "true" ]]; then
            printf "\n>:green_circle:  All environments in $1 are healthy" >>slack-message.txt
        fi
    fi
}

function check_status () {
    printf "\n*$1 Status:*" >>slack-message.txt
    add_environments $1
    uptime $1
    do_failures_exist $1
}

declare -A Toffee=( 
[no_fail_msg]=
)

# function runner
APPS=("Toffee" "Plum")
printf "\n:detective-pikachu: _*Check Toffee/Plum Status*_ \n" >>slack-message.txt

# Check app status first before output
for APP in ${APPS[@]}; do
    # add_environments $APP
    # uptime $APP

    check_status $APP
done
printf "%s\n" "${Toffee[no_fail_msg]}" >>slack-message.txt


# format output, print if no failure exist
# if [[ $failures_exist_toffee != "true" && $failures_exist_plum != "true" ]]; then
#     printf "\n>:green_circle:  All environments are healthy" >>slack-message.txt
# else

#     # print if failure exist, $1 data does not persist need to re run logic
#     for APP in ${APPS[@]}; do
#         check_status $APP
#     done
# fi

# ------------



# need to run uptime on both arrays
# need to check for failure, if not then simple printf else well think of that later

