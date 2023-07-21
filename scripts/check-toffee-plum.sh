#!/usr/bin/env bash

ENVIRONMENTS=(sbox ithc demo prod)

function environments() {
        if [[ "$APP" == "toffee" ]]; then
        ENVIRONMENTS+=(dev, test, staging)
        elif [[ "$APP" == "plum" ]]; then
        ENVIRONMENTS+=(preview, perftest, aat)
        fi
}

function logic() {
    statuscode=$(curl --max-time 30 --retry 20 --retry-delay 15 -s -o /dev/null -w "%{http_code}"  https://$APP.$ENV.platform.hmcts.net)

    if [[ "$ENVIRONMENT" == "demo" && $statuscode -eq 302 ]]; then
        printf "\n>:green_circle: https://$APP.$ENV.platform.hmcts.net" >> slack-message.txt
    elif [[ $statuscode -eq 200 ]]; then
        printf "\n>:green_circle: https://$APP.$ENV.platform.hmcts.net" >> slack-message.txt
    else
        printf "\n>:red_circle: https://$APP.$ENV.platform.hmcts.net" >> slack-message.txt
    fi
}

function uptime() {
    for ENV in {$ENVIRONMENTS} 
    do
        echo $ENVIRONMENTS
    done
}

### test toffee
APP="toffee"
environments
uptime

### test plum
APP="plum"
environments
uptime