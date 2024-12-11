# dtspo-daily-monitoring

Daily monitoring checks for DTS Platform Operations BAU team

## Adding a new pipeline to be monitored

Update `azure-pipelines.yaml` by adding a new entry to the ado_pipeline parameter:

```yaml
- project: 'PlatformOperations'
  definitionId: '123'
  timeForAmber: '3'
  timeForRed: '5'
  pipelineName: my_pipeline_name
  branchName: "refs/heads/master"
```

If your pipeline name uses dashes, `-`, and no spaces, then just enter it as is without any quotes e.g. `sds-azure-platform`.

If your pipeline name has spaces, e.g. `My Pipeline`, then replace the spaces with underscores here, e.g. `My_Pipeline`.

The underscores will be removed in the script and replaced with spaces for the slack notification.

This is due to an issue in the bash task for Azure Pipelines where it does not seem to handle spaces very well.

If your pipeline name uses underscores, please replace these with spaces or dashes in Azure DevOps.

`timeForAmber` and `timeForRed` are the amount of time in days that a pipeline should go without a successful run before showing an amber or red circle in the slack message.

## Testing slack message updates

When you submit a pull request, a direct slack message will be sent to you so you can check the format is working.

When you merge your approved PR, the messages will be sent to the `#dtspo-daily-checks` channel.

## GitHub workflow

To add a workflow to be monitored add it to the azure-pipelines.yaml within the gh_workflows section as below

```yaml
parameters:
  - name: gh_workflows
    type: object
    default:
      - repo: 'some_repo' # repository the code resides in
        branch: 'master' # branch you wish to monitor
        run: 'some_action' # The name specified in the YAML of workflow. This is optional if left blank the process will report on all Actions.

```

Note: This process requires uses name key set in the github actions YAML in the repo you are wanting to monitor the name key should be one word or use underscores as a separator. If you are getting blank slack messages it is because
the name is not set or set incorrectly. If it is not set the path can be used but looks bad in the slack messages.
