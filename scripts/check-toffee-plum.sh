#!/usr/bin/env bash
function subscription () {
   
        SUBSCRIPTION_ID=$(jq -r '.id' <<< $subscription)
        az account set -s $SUBSCRIPTION_ID
        CLUSTERS=$(az resource list \
        --resource-type Microsoft.ContainerService/managedClusters \
        --query "[?tags.application == 'true']" -o json)
}

function cluster () {
        RESOURCE_GROUP=$(jq -r '.resourceGroup' <<< $cluster)
        NAME=$(jq -r '.name' <<< $cluster)
}

function logic () {
    if [[ "$ENVIRONMENT" == "demo" && $statuscode -eq 302 ]]; then
        printf "\n>:green_circle: ttps://$APPLICATION.platform.hmcts.net" >> slack-message.txt
    elif [[ $statuscode -eq 200 ]]; then
        printf "\n>:green_circle: ttps://$APPLICATION.platform.hmcts.net" >> slack-message.txt
    else
        printf "\n>:red_circle: ttps://$APPLICATION.platform.hmcts.net" >> slack-message.txt
    fi
}


SUBSCRIPTIONS=$(az account list -o json)
jq -c '.[]' <<< $SUBSCRIPTIONS | while read subscription; do
subscription
    jq -c '.[]' <<< $CLUSTERS | while read cluster; do
        cluster

        BUSINESS_AREA=$(jq -r '.tags.businessArea' <<< $cluster)
        if [[ "$BUSINESS_AREA" == "Cross-Cutting" ]]; then
            APP="toffee"
        elif [[ "$BUSINESS_AREA" == "CFT" ]]; then
            APP="plum"
        fi

        ENVIRONMENT=$(jq -r '.tags.environment' <<< $cluster)

        if [[ "$ENVIRONMENT" == "sandbox" || "$ENVIRONMENT" == "Sandbox" ]]; then
            ENV="sbox"
        elif [[ "$ENVIRONMENT" == "testing" ]]; then
            ENV="perftest"
        else
            ENV="$ENVIRONMENT"
        fi

        ts_echo "Test that $APP works in $ENVIRONMENT after $NAME start-up"
        if [[ "$ENVIRONMENT" == "testing" && "$APP" == "toffee" ]]; then
            APPLICATION="$APP.test"
        elif [[ "$ENVIRONMENT" == "testing" && "$APP" == "plum" ]]; then
            APPLICATION="$APP.perftest"
        else 
            APPLICATION="$APP.$ENVIRONMENT"
        fi

        statuscode=$(curl --max-time 30 --retry 20 --retry-delay 15 -s -o /dev/null -w "%{http_code}"  https://$APPLICATION.platform.hmcts.net)

        if [[ "$APP" == "toffee" ]]; then
            logic
        elif [[ "$APP" == "plum" ]]; then
            logic
        fi


        
    done
done