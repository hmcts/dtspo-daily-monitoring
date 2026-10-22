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

lookup_resource() {
    local apiVersion=${1:-}
    local args=(resource show --ids "$resourceId" --output json --only-show-errors)
    if [[ -n "$apiVersion" ]]; then
        args+=(--api-version "$apiVersion")
    fi
    az "${args[@]}" > "$workDir/resource.json" 2> "$workDir/error.txt"
}

# Azure CLI defaults to the newest API version, which may not be registered for the resource's
# region. Pick the newest stable version Azure reports as supported.
supported_api_version() {
    sed -n "s/.*The supported api-versions are '\([^']*\)'.*/\1/p" "$workDir/error.txt" \
        | head -n 1 | tr ',' '\n' | tr -d ' ' | grep -Ev -- '-preview$' | sort | tail -n 1 || true
}

while IFS= read -r resourceId; do
    echo "Checking: $resourceId" >&2
    detail=
    lookupSucceeded=0
    if lookup_resource; then
        lookupSucceeded=1
    elif grep -Eq '^ERROR: \(NoRegisteredProviderFound\)' "$workDir/error.txt"; then
        fallbackVersion=$(supported_api_version)
        if [[ -n "$fallbackVersion" ]]; then
            echo "Retrying with API version $fallbackVersion" >&2
            if lookup_resource "$fallbackVersion"; then
                lookupSucceeded=1
            fi
        fi
    fi

    if [[ "$lookupSucceeded" -eq 1 ]]; then
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
