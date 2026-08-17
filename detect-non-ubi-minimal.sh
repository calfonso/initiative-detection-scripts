#!/bin/bash

IMAGE_REF="${1}"

if [[ -z "${IMAGE_REF}" ]]; then
    echo '{"affected":false,"summary":"No image reference provided","severity":"info","hits":[],"implementation_spec":""}'
    exit 0
fi

# Allowed base image name patterns (case-insensitive grep -iE pattern)
ALLOWED_BASE_PATTERN="ubi9-minimal|ubi-minimal|ubi9-micro|ubi-micro|nodejs-24-minimal|nodejs-22-minimal|nodesj-24-minimal|python-312-minimal|python-214-minimal"

echo "Inspecting image: ${IMAGE_REF}" >&2

# Fetch full OCI config (includes history and labels)
CONFIG_JSON=$(skopeo inspect --override-arch amd64 --config "docker://${IMAGE_REF}" 2>&1)
CONFIG_EXIT=$?

if [[ ${CONFIG_EXIT} -ne 0 ]]; then
    ERROR_MSG=$(echo "${CONFIG_JSON}" | head -3 | tr '"' "'" | tr '\n' ' ')
    RESULT=$(jq -n --arg err "Error inspecting image: ${ERROR_MSG}" \
        '{"affected":false,"summary":$err,"severity":"info","hits":[],"implementation_spec":""}')
    echo "${RESULT}"
    exit 0
fi

echo "Successfully retrieved image config" >&2

# ---- OSBS label-walking heuristic ----
# Red Hat/OSBS-built images carry LABEL instructions in the build history.
# The *first* LABEL entry with a resolvable (non-templated) name= value
# identifies the base image, because later LABEL entries overwrite those
# keys with the final image's identity.
base_name=""
base_version=""
base_component=""

while IFS= read -r created_by; do
    [[ "$created_by" == *"LABEL"* ]] || continue

    # Extract name="..." value — require whitespace before name= to
    # avoid matching $name= (templated). Skip values containing $.
    name=$(echo "$created_by" | sed -nE 's/.*[[:space:]]name="([^"]+)".*/\1/p' | head -1)
    [[ -z "$name" || "$name" == *'$'* ]] && continue

    base_name="$name"
    base_version=$(echo "$created_by" | sed -nE 's/.*version="([^"]+)".*/\1/p' | head -1)
    base_component=$(echo "$created_by" | sed -nE 's/.*com\.redhat\.component="([^"]+)".*/\1/p' | head -1)
    break
done < <(jq -r '.history[]?.created_by // empty' <<<"$CONFIG_JSON")

echo "Detected base image: name=${base_name:-unknown} version=${base_version:-} component=${base_component:-}" >&2

# Check whether the detected base name matches an approved minimal base
if [[ -n "${base_name}" ]] && echo "${base_name}" | grep -qiE "(${ALLOWED_BASE_PATTERN})"; then
    echo "Base image '${base_name}' matches approved pattern" >&2
    RESULT=$(jq -n \
        --arg summary "Base image '${base_name}' (version=${base_version:-unknown}, component=${base_component:-unknown}) is an approved minimal base" \
        '{"affected":false,"summary":$summary,"severity":"info","hits":[],"implementation_spec":""}')
    echo "${RESULT}"
else
    echo "Base image '${base_name:-unknown}' does not match any approved pattern" >&2

    # Build a descriptive match string from the detected base
    MATCH=""
    if [[ -n "${base_name}" ]]; then
        MATCH="base_name=${base_name}"
        [[ -n "${base_version}" ]] && MATCH="${MATCH}; base_version=${base_version}"
        [[ -n "${base_component}" ]] && MATCH="${MATCH}; base_component=${base_component}"
    else
        # Fallback: pull from final config labels if OSBS heuristic found nothing
        COMPONENT=$(echo "${CONFIG_JSON}" | jq -r '.config.Labels["com.redhat.component"] // ""' 2>/dev/null)
        IMAGE_NAME_LABEL=$(echo "${CONFIG_JSON}" | jq -r '.config.Labels["name"] // ""' 2>/dev/null)
        BASE_IMAGE_LABEL=$(echo "${CONFIG_JSON}" | jq -r '
            .config.Labels["io.buildah.base-image"] //
            .config.Labels["base-image"] //
            .config.Labels["org.opencontainers.image.base.name"] //
            ""
        ' 2>/dev/null)

        CONTEXT_PARTS=""
        [[ -n "${COMPONENT}" ]]        && CONTEXT_PARTS="${CONTEXT_PARTS}com.redhat.component=${COMPONENT}; "
        [[ -n "${IMAGE_NAME_LABEL}" ]] && CONTEXT_PARTS="${CONTEXT_PARTS}name=${IMAGE_NAME_LABEL}; "
        [[ -n "${BASE_IMAGE_LABEL}" ]] && CONTEXT_PARTS="${CONTEXT_PARTS}base-image=${BASE_IMAGE_LABEL}; "
        MATCH="${CONTEXT_PARTS:-No base image identity could be determined from image history or labels}"
        MATCH="${MATCH%%; }"
    fi

    RESULT=$(jq -n \
        --arg file        "${IMAGE_REF}" \
        --arg match       "${MATCH}" \
        --arg description "Image base is not an approved minimal base image. Approved bases: ubi9-minimal, ubi-minimal, ubi9-micro, ubi-micro, nodejs-24-minimal, nodejs-22-minimal, python-312-minimal, python-214-minimal. Images must be built FROM an approved minimal base to reduce attack surface and ensure policy compliance." \
        --arg suggestion  "Rebuild this image using one of the approved minimal base images as the FROM instruction: ubi9-minimal, ubi-minimal, ubi9-micro, ubi-micro, nodejs-24-minimal, nodejs-22-minimal, python-312-minimal, or python-214-minimal" \
        '{
            "affected": true,
            "summary": "Image base is not an approved minimal base image",
            "severity": "medium",
            "hits": [
                {
                    "file":        $file,
                    "line":        0,
                    "match":       $match,
                    "description": $description,
                    "suggestion":  $suggestion
                }
            ],
            "implementation_spec": ""
        }')
    echo "${RESULT}"
fi
