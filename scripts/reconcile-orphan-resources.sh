#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: bash $0 /path/to/deletionStatus.json" >&2
    echo "Read-only preview: writes JSON to stdout; does not delete, update status, or post to Slack." >&2
    exit 1
fi

sourceFile=$1
for dependency in az jq; do
    if ! command -v "$dependency" >/dev/null 2>&1; then
        echo "Required command not found: $dependency" >&2
        exit 1
    fi
done

workDir=$(mktemp -d)
trap 'rm -f "$workDir/ids.json" "$workDir/results.jsonl" "$workDir/resource.json" "$workDir/error.txt"; rmdir "$workDir"' EXIT

# Reject malformed records before making any Azure requests.
jq -e '
    if type != "array" then error("Expected an array of historical deletion failures")
    else map(
        if type != "object" then error("Expected a failure object")
        elif (.message | type) != "string" then error("Expected a failure message")
        elif (.message | test("az resource delete --ids (?<id>/subscriptions/[^/[:space:]]+/resourceGroups/[^[:space:]]+) --verbose")) then
            .message | capture("az resource delete --ids (?<id>/subscriptions/[^/[:space:]]+/resourceGroups/[^[:space:]]+) --verbose").id
        else error("Failure message does not contain a resource ID")
        end
    )
    end
' "$sourceFile" > "$workDir/ids.json"

: > "$workDir/results.jsonl"
unverifiedCount=0

while IFS= read -r resourceId; do
    echo "Checking: $resourceId" >&2
    detail=
    if az resource show --ids "$resourceId" --output json --only-show-errors \
        > "$workDir/resource.json" 2> "$workDir/error.txt"; then
        if jq -e --arg id "$resourceId" '
            type == "object" and (.id | type) == "string" and
            ((.id | ascii_downcase) == ($id | ascii_downcase))
        ' "$workDir/resource.json" >/dev/null 2>&1; then
            status=exists
        else
            status=unverified
            detail="Azure CLI returned success without a matching resource ID; existence could not be verified."
        fi
    elif grep -Eq '^ERROR: \((ResourceNotFound|ResourceGroupNotFound)\)' "$workDir/error.txt"; then
        status=not_found
        detail=$(< "$workDir/error.txt")
    else
        status=unverified
        detail=$(< "$workDir/error.txt")
        if [[ -z "$detail" ]]; then
            detail="Azure CLI failed without an error message; existence could not be verified."
        fi
    fi

    if [[ "$status" == unverified ]]; then
        unverifiedCount=$((unverifiedCount + 1))
        echo "Could not verify $resourceId: $detail" >&2
    fi

    jq -n --arg id "$resourceId" --arg status "$status" --arg detail "$detail" \
        '{id: $id, status: $status} + (if $detail == "" then {} else {detail: $detail} end)' \
        >> "$workDir/results.jsonl"
done < <(jq -r '.[]' "$workDir/ids.json")

jq -s --arg checkedAt "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --arg sourceFile "$sourceFile" '
    {
        checkedAt: $checkedAt,
        sourceFile: $sourceFile,
        summary: {
            exists: (map(select(.status == "exists")) | length),
            notFound: (map(select(.status == "not_found")) | length),
            unverified: (map(select(.status == "unverified")) | length)
        },
        resources: .
    }
' "$workDir/results.jsonl"

if [[ "$unverifiedCount" -gt 0 ]]; then
    echo "$unverifiedCount resource(s) could not be verified. Review the preview before changing any monitoring." >&2
    exit 1
fi
