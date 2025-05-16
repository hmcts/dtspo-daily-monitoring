#!/usr/bin/env bash

# This script will check the Azure DevOps pipeline definition supplied for last successful run.
# If older than the supplied dates (amber and red) it will save the relevant message to the
# slackThread variable and save the final output to file

### Setup script environment
set -e

# Source central functions script
source scripts/common-functions.sh

adoToken=
adoProject=
adoPipelineName=
adoPipelineDefinitionId=
adoPipelineBranch=
adoTimeForAmber=3
adoTimeForRed=5

usage(){
>&2 cat << EOF
  ------------------------------------------------
  Script to check GitHub page expiry
  ------------------------------------------------
  Usage: $0
      [ -t | --adoToken ]
      [ -p | --adoProject ]
      [ -n | --adoPipelineName ]
      [ -i | --adoPipelineDefinitionId ]
      [ -b | --adoPipelineBranch ]
      [ -a | --adoTimeForAmber ]
      [ -r | --adoTimeForRed ]
      [ -h | --help ]
EOF
exit 1
}

args=$(getopt -a -o t:p:n:i:b:a:r:h: --long adoToken:,adoProject:,adoPipelineName:,adoPipelineDefinitionId:,adoPipelineBranch:,adoTimeForAmber:,adoTimeForRed:,help -- "$@")
if [[ $? -gt 0 ]]; then
    usage
fi

eval set -- ${args}
while :
do
    case $1 in
        -h | --help)                    usage                       ; shift   ;;
        -t | --adoToken)                adoToken=$2                 ; shift 2 ;;
        -p | --adoProject)              adoProject=$2               ; shift 2 ;;
        -m | --adoPipelineName)         adoPipelineName=$2          ; shift 2 ;;
        -i | --adoPipelineDefinitionId) adoPipelineDefinitionId=$2  ; shift 2 ;;
        -b | --adoPipelineBranch)       adoPipelineBranch=$2        ; shift 2 ;;
        -a | --adoTimeForAmber)         adoTimeForAmber=$2          ; shift 2 ;;
        -r | --adoTimeForRed)           adoTimeForRed=$2            ; shift 2 ;;
        # -- means the end of the arguments; drop this, and break out of the while loop
        --) shift; break ;;
        *) >&2 echo Unsupported option: $1
            usage ;;
    esac
done

if [[ -z "$adoToken" || -z "$adoProject" || -z "$adoPipelineName" || -z "$adoPipelineDefinitionId" || -z "$adoPipelineBranch" ]]; then
    {
        echo "---------------------------------"
        echo 'Please supply all of:'
        echo '- Azure DevOps Token '
        echo '- Azure DevOps Project name '
        echo '- Azure DevOps Pipeline Name'
        echo '- Azure DevOps Pipeline Definition Id'
        echo '- Azure DevOps Pipeline Branch'
        echo "---------------------------------"
    } >&2
    exit 1
fi

# Setup variables
slackThread=""
pipelineName=$(echo $adoPipelineName | sed 's/_/ /g' | sed 's/"//g')
branchName=$(echo $adoPipelineBranch | sed 's/"//g')
isoTimeAmber=$(date -d "-${adoTimeForAmber} days" +"%Y-%m-%dT%H:%M:%SZ" )
echo "Amber Time since: $isoTimeAmber"
isoTimeRed=$(date -d "-${adoTimeForRed} days" +"%Y-%m-%dT%H:%M:%SZ" )
echo "Red Time since: $isoTimeRed"

slackLinkFormat="<https://dev.azure.com/hmcts/$adoProject/_build?definitionId=$adoPipelineDefinitionId|$pipelineName pipeline>"

amberCheck=$(curl -u :$adoToken "https://dev.azure.com/hmcts/$adoProject/_apis/build/builds?api-version=7.0&definitions=$adoPipelineDefinitionId&branchName=$branchName&resultFilter=succeeded&\$top=1&minTime=$isoTimeAmber" | jq -r .count)
redCheck=$(curl -u :$adoToken "https://dev.azure.com/hmcts/$adoProject/_apis/build/builds?api-version=7.0&definitions=$adoPipelineDefinitionId&branchName=$branchName&resultFilter=succeeded&\$top=1&minTime=$isoTimeRed" | jq -r .count)

if [ "$redCheck" != 1 ]; then
  slackThread+=":red_circle: $slackLinkFormat hasn't run successfully in ${adoTimeForRed} days!"
elif [ "$amberCheck" != 1 ]; then
  slackThread+=":yellow_circle: $slackLinkFormat hasn't run successfully in ${adoTimeForAmber} days!"
else
  slackThread+=":green_circle: $slackLinkFormat ran successfully in the last ${adoTimeForAmber} days"
fi

echo $slackThread >> ado-pipeline-status.txt
