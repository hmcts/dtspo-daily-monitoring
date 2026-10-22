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

## Slack notifications

Monitoring alerts are sent to the `#dtspo-daily-checks` channel for all pipeline runs (scheduled, main branch, and pull requests).

The orphan-resource check now verifies the saved historical failure IDs using
read-only Azure lookups on every run. Slack lists only confirmed existing entries
under **Historical cleanup failures — still exists**, with a UTC verification
timestamp. Confirmed missing entries are omitted. Authentication, permission, and
API failures appear in a separate **Historical cleanup verification errors**
notification and fail the check (the pipeline continues via `continueOnError`).
Download or malformed-input failures also produce an error notification.
If all entries are confirmed missing, no Slack alert is sent.

The check uses the existing `service_connection` Azure service connection.
Its identity needs read access to every subscription/resource in the historical
list; inaccessible resources remain unverified, never assumed deleted. It does
not discover new orphans, delete anything, alter the saved status file, or enable
the cleanup workflow.

### Read-only verification of historical orphan-resource failures

The orphan-resource Slack check reads a saved failure list, which may be stale
if the cleanup workflow has stopped running. To verify those exact resource IDs
without deleting anything, sign in to Azure CLI with read access to the relevant
subscriptions and run:

```bash
bash scripts/reconcile-orphan-resources.sh \
  ../dtspo-orphan-resources-cleanup/status/deletionStatus.json \
  > /tmp/orphan-resource-preview.json
jq '.summary, .resources' /tmp/orphan-resource-preview.json
```

Use an up-to-date checkout of the cleanup repository as the input. The checker
only invokes `az resource show`; it does not run the cleanup script, change the
saved failure list, or send Slack messages. Its JSON preview includes a UTC
verification timestamp and classifies each resource as:

- `exists`: previously failed cleanup and still exists, not necessarily orphaned
  or safe to delete.
- `not_found`: Azure explicitly returned `ResourceNotFound` or
  `ResourceGroupNotFound`.
- `unverified`: authentication, permissions, subscription access, API errors,
  or an unexpected response prevented verification.

If any check is unverified, the script exits non-zero but still outputs the
preview with all results and error details. Do not treat those entries as gone.
Review the preview before making any changes to daily monitoring. This checks
only historical failures, not new orphan candidates, and leaves live deletion
disabled. This command is a local preview only; the daily pipeline separately
runs the same checker before sending its Slack notifications.

Run the checker tests (mocked Azure CLI; no network requests) with:

```bash
python3 -m unittest discover -s tests -p 'test_*.py'
```

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
