#!/bin/bash

REPO_DIR="${1}"

if [[ -z "${REPO_DIR}" || ! -d "${REPO_DIR}" ]]; then
    echo '{"affected":false,"summary":"No valid repo directory provided","severity":"info","hits":[],"implementation_spec":""}'
    exit 0
fi

echo "Scanning for Dockerfiles using :latest or no tag in ${REPO_DIR}" >&2

HITS="[]"
AFFECTED="false"

while IFS= read -r dockerfile; do
    rel_path="${dockerfile#${REPO_DIR}/}"

    # Find FROM lines that use :latest or have no tag at all
    # Skip ARG-templated images (FROM ${VAR}) and scratch
    while IFS= read -r line_info; do
        line_num="${line_info%%:*}"
        line_text="${line_info#*:}"

        # Normalize: strip comments, trim whitespace
        clean=$(echo "${line_text}" | sed 's/#.*//' | xargs)
        [[ -z "${clean}" ]] && continue

        # Extract the image reference (second token after FROM, before optional AS)
        image=$(echo "${clean}" | awk '{print $2}')
        [[ -z "${image}" ]] && continue

        # Skip templated (${...}), scratch, and --platform flags
        [[ "${image}" == *'${'* ]] && continue
        [[ "${image}" == "scratch" ]] && continue
        [[ "${image}" == "--"* ]] && {
            image=$(echo "${clean}" | awk '{print $3}')
            [[ -z "${image}" || "${image}" == *'${'* || "${image}" == "scratch" ]] && continue
        }

        # Check: explicit :latest tag
        if [[ "${image}" == *":latest" ]]; then
            AFFECTED="true"
            HITS=$(echo "${HITS}" | jq --arg file "${rel_path}" --argjson line "${line_num}" \
                --arg match "${line_text}" \
                --arg desc "FROM uses :latest tag. Pin to a specific version for reproducible builds." \
                --arg sug "Replace '${image}' with a version-pinned image reference" \
                '. + [{"file":$file,"line":$line,"match":$match,"description":$desc,"suggestion":$sug}]')
            echo "  HIT: ${rel_path}:${line_num} — uses :latest" >&2
            continue
        fi

        # Check: no tag at all (no colon, no digest @)
        if [[ "${image}" != *":"* && "${image}" != *"@"* ]]; then
            AFFECTED="true"
            HITS=$(echo "${HITS}" | jq --arg file "${rel_path}" --argjson line "${line_num}" \
                --arg match "${line_text}" \
                --arg desc "FROM has no version tag, which implicitly pulls :latest. Pin to a specific version." \
                --arg sug "Add a version tag to '${image}', e.g. '${image}:1.0'" \
                '. + [{"file":$file,"line":$line,"match":$match,"description":$desc,"suggestion":$sug}]')
            echo "  HIT: ${rel_path}:${line_num} — no tag (implicit :latest)" >&2
            continue
        fi
    done < <(grep -n -i '^[[:space:]]*FROM ' "${dockerfile}" 2>/dev/null)
done < <(find "${REPO_DIR}" -maxdepth 3 -type f \( -name "Dockerfile" -o -name "Dockerfile.*" -o -name "*.Dockerfile" -o -name "Containerfile" \) 2>/dev/null)

HIT_COUNT=$(echo "${HITS}" | jq 'length')

if [ "${AFFECTED}" = "true" ]; then
    SUMMARY="${HIT_COUNT} Dockerfile FROM instruction(s) using :latest or untagged base images"
else
    SUMMARY="All Dockerfile FROM instructions use pinned versions"
fi

echo "Scan complete: affected=${AFFECTED}, hits=${HIT_COUNT}" >&2

jq -n \
    --argjson affected "${AFFECTED}" \
    --arg summary "${SUMMARY}" \
    --argjson hits "${HITS}" \
    '{
        "affected": $affected,
        "summary": $summary,
        "severity": "low",
        "hits": $hits,
        "implementation_spec": ""
    }'
