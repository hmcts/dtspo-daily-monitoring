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
    if [[ $statuscode == 200 ]] && [[ $1 == "Toffee" ]]; then # revert if back to !=
        # failure_msg_toffee="\n>:red_circle:  <$url| $ENV> is unhealthy"
        failure_msg_toffee+="\n>:green_circle:  <$url| $ENV> is healthy"
        failures_exist_toffee="true"


    elif [[ $statuscode != 200 ]] && [[ $1 == "Plum" ]]; then
        failure_msg_plum+="\n>:red_circle:  <$url| $ENV> is unhealthy"
        failures_exist_plum="true"
    fi
}

function uptime() {
    for ENV in ${ENVIRONMENTS[@]}; do
        status_code $1
        failure_check $1 
    done
}

# function do_failures_exist() {
#     if [[ $1 = "Toffee" ]]; then
#         if [[ $failures_exist_toffee != "true" ]]; then
#             success_msg_toffee+="\n>:green_circle:  All environments in $1 are healthy" 
#         fi

#     elif [[ $1 = "Plum" ]]; then
#         if [[ $failures_exist_plum != "true" ]]; then
#             success_msg_plum+="\n>:green_circle:  All environments in $1 are healthy"
#         fi
#     fi
# }

function check_status() {
    add_environments $1
    uptime $1
    # do_failures_exist $1
}

# mb make a default slack msg
# print generic msg if no faults are there
# create a different slack msg if faults occur 

function success_msg() {
    printf "\n>:green_circle:  All environments are healthy" >>slack-message.txt
}

function format_status() {
    printf "\n*Toffee Status:*" >>slack-message.txt
    if [[ $failures_exist_toffee == "true" ]]; then
        printf '%s\n' "${failure_msg_toffee[@]}" >>slack-message.txt
    else
        success_msg
    fi

    printf "\n*Plum Status:*" >>slack-message.txt
    if [[ $failures_exist_plum == "true" ]]; then
        printf '%s\n' "${failure_msg_plum[@]}" >>slack-message.txt
    else
        success_msg
    fi
}

# hold any failure or success messages 
failure_msg_toffee=()
# success_msg_toffee=()

failure_msg_plum=()
# success_msg_plum=()


APPS=("Toffee" "Plum")
printf "\n:detective-pikachu: _*Check Toffee/Plum Status*_ \n" >>slack-message.txt

# Check app status first
for APP in ${APPS[@]}; do
    check_status $APP
done

# format the output
if [[ $failures_exist_toffee == "true" ]] || [[ $failures_exist_plum == "true" ]]; then
    format_status
else
    success_msg
fi
