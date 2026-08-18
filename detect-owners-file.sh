#!/bin/bash

REPO_DIR="${1}"

if [[ -z "${REPO_DIR}" || ! -d "${REPO_DIR}" ]]; then
    echo '{"affected":false,"summary":"No valid repo directory provided","severity":"info","hits":[],"implementation_spec":""}'
    exit 0
fi

echo "Scanning for missing OWNERS/CODEOWNERS files in ${REPO_DIR}" >&2

HITS="[]"

# Check for any of the standard ownership files
OWNERS_FILES=(
    "OWNERS"
    "CODEOWNERS"
    ".github/CODEOWNERS"
    "docs/CODEOWNERS"
    "MAINTAINERS"
    "MAINTAINERS.md"
)

found_any="false"
found_names=""

for f in "${OWNERS_FILES[@]}"; do
    if [ -f "${REPO_DIR}/${f}" ]; then
        found_any="true"
        found_names="${found_names}${f}, "
        echo "  Found: ${f}" >&2
    fi
done

if [ "${found_any}" = "true" ]; then
    found_names="${found_names%, }"
    echo "Ownership files present: ${found_names}" >&2
    jq -n \
        --arg summary "Repo has ownership files: ${found_names}" \
        '{
            "affected": false,
            "summary": $summary,
            "severity": "info",
            "hits": [],
            "implementation_spec": ""
        }'
else
    echo "No ownership files found" >&2
    HITS=$(jq -n \
        '[{
            "file": ".",
            "line": 0,
            "match": "No OWNERS, CODEOWNERS, or MAINTAINERS file found in repo root or .github/",
            "description": "This repository has no ownership file. Every repo should have an OWNERS or CODEOWNERS file so that reviewers and approvers are clearly defined and code review can be automatically assigned.",
            "suggestion": "Add an OWNERS file (Kubernetes-style) or a CODEOWNERS file (.github/CODEOWNERS for GitHub) that lists the team or individuals responsible for this repo."
        }]')

    jq -n \
        --argjson hits "${HITS}" \
        '{
            "affected": true,
            "summary": "No OWNERS or CODEOWNERS file found",
            "severity": "low",
            "hits": $hits,
            "implementation_spec": ""
        }'
fi
