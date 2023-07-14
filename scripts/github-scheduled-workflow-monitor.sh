# Add a script to check the status of github actions scheduled workflows. List of workflows are listed in the above link.
# azure pipeline updated accordingly.
# Make sure similar pattern is followed wrt icons, colours etc..
usage() { 
    echo "$0 Usage: specify -t github-api-token -r repo name -b branch name -g github workflow run (optional) -o github owner" 
    }
[ $# -eq 0 ] && usage
while getopts ":t:r:b:o:g:" arg; do
  case $arg in
    t) # Specify token value.
        token=${OPTARG}
      ;;
    r) # Specify repo name
        repo=${OPTARG}
      ;;
    b) # Specify branch
      branch=${OPTARG}
      ;;
    g) # Specity specific run (optional)
      run=${OPTARG}
      ;; 
    o) # Specify Owner of Github
      owner=${OPTARG}
      ;;
  esac
done

# a function to make it easier to print the message usage: message [red | yellow | green]
print_message() {
    printf "\n:${1}_circle Workflow name: <${html_url}|_*${name}*_> Workflow status: ${workflow_status} Workflow conclusion: ${conclusion} Started at: ${run_started_at} \n\n" >> slack-message.txt
}



printf "\n:GitHub sheduled Workflow status: <https://https://github.com/${owner}/> \n\n" >> slack-message.txt

# Check if we need to intergoate a specific run or all of the runs for that workflow

if [[ -z "${run}" ]];
then
    # no specific run specified therefore run for each workflow in the repo
    # loop through list of workflows in repo to monitor
    workflows_response=$(curl -s -L -H "Accept: application/vnd.github+json" -H "Authorization: Bearer ${token}" -H "X-GitHub-Api-Version: 2022-11-28" https://api.github.com/repos/${owner}/${repo}/actions/workflows | jq -r '.workflows[] | [.id , .name] |@csv')
    while read -r w;
    do    
        # loop through the $workflows_respose and for each of the workflows find their name and id   
        while IFS=, read -r id name;
        do
            # Get the last response for that workflow id and specified branch 
            workflow_status=$(curl -s -L -H "Accept: application/vnd.github+json" -H "Authorization: Bearer ${token}" -H "X-GitHub-Api-Version: 2022-11-28" "https://api.github.com/repos/${owner}/${repo}/actions/workflows/${id}/runs?per_page=1&branch=$branch" | jq -r '.workflow_runs[] | [.status , .conclusion , .html_url , .run_started_at] |@csv')
            while IFS=, read -r workflow_status conclusion html_url run_started_at;
            do
                # clean up responses
                workflow_status=$(echo ${workflow_status} | tr -d '"')
                conclusion=$(echo ${conclusion} |tr -d '"')
                run_started_at=$(echo ${run_started_at} | sed -e 's/T/ /; s/Z//')

                # Write slack message dependant on status and conclusion
                if [ "${conclusion}" = "success" ];
                then
                    print_message green
                elif [[ "${workflow_status}" == "waiting" ]] | [[ "${workflow_status}" == "pending" ]] | [[ "${workflow_status}" == "in_progress" ]] | [[ "${workflow_status}" == "queued" ]] | [[ "${workflow_status}" == "waiting" ]]
                then
                    print_message yellow
                else 
                    print_message red
                fi    
            done  <<< ${workflow_status}
        done <<< $w 
    done <<< ${workflows_response}
else
    # A specific workflow run was specified interogate only that one and get its id
    workflows_response_id=$(curl -s -L -H "Accept: application/vnd.github+json" -H "Authorization: Bearer ${token}" -H "X-GitHub-Api-Version: 2022-11-28" "https://api.github.com/repos/${owner}/${repo}/actions/workflows" | jq -r --arg TEST "$run" '[.workflows[]]| map(select(.name==$TEST))| [.[].id , .[].name] |@csv')
    echo $workflows_response_id
     while IFS=, read -r id name;
        do
            name=$(echo $name | tr -d '"')
            echo "id is: " $id "name is: "$name "owner:" $owner "repo " $repo "branch" $branch
            # Get the last response for that workflow id and specified branch and store status and conclusion
            workflow_status=$(curl -s -L -H "Accept: application/vnd.github+json" -H "Authorization: Bearer ${token}" -H "X-GitHub-Api-Version: 2022-11-28" "https://api.github.com/repos/${owner}/${repo}/actions/workflows/${id}/runs?per_page=1&branch=$branch" | jq -r '.workflow_runs[] | [.status , .conclusion , .html_url , .run_started_at] |@csv')
            # Read stored response and split status and conclusion then 
            while IFS=, read -r workflow_status conclusion html_url run_started_at;
            do
                # clean up responses
                workflow_status=$(echo ${workflow_status} | tr -d '"')
                conclusion=$(echo ${conclusion} |tr -d '"')
                run_started_at=$(echo ${run_started_at} | sed -e 's/T/ /; s/Z//')

                # Write slack message dependant on status and conclusion
                if [ "${conclusion}" = "success" ];
                then
                    print_message green
                elif [[ "${workflow_status}" == "waiting" ]] | [[ "${workflow_status}" == "pending" ]] | [[ "${workflow_status}" == "in_progress" ]] | [[ "${workflow_status}" == "queued" ]] | [[ "${workflow_status}" == "waiting" ]]
                then
                    print_message yellow
                else 
                    print_message red
                fi    
            done  <<< ${workflow_status}
        done <<< ${workflows_response_id}
fi
