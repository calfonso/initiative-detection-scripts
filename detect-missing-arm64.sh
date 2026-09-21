#!/bin/bash

IMAGE_REF="${1}"

if [[ -z "${IMAGE_REF}" ]]; then
    echo '{"affected":false,"summary":"No image reference provided","severity":"info","hits":[],"implementation_spec":""}'
    exit 0
fi

echo "Checking arm64/aarch64 availability for: ${IMAGE_REF}" >&2

# Fetch the raw manifest — this could be a manifest list (multi-arch)
# or a single-platform manifest.
RAW=$(skopeo inspect --raw "docker://${IMAGE_REF}" 2>&1)
RAW_EXIT=$?

if [[ ${RAW_EXIT} -ne 0 ]]; then
    ERROR_MSG=$(echo "${RAW}" | head -3 | tr '"' "'" | tr '\n' ' ')
    jq -n --arg err "Error inspecting image: ${ERROR_MSG}" \
        '{"affected":false,"summary":$err,"severity":"info","hits":[],"implementation_spec":""}'
    exit 0
fi

# Determine the manifest type
MEDIA_TYPE=$(echo "${RAW}" | jq -r '.mediaType // ""' 2>/dev/null)
SCHEMA_VERSION=$(echo "${RAW}" | jq -r '.schemaVersion // 0' 2>/dev/null)

echo "Manifest mediaType=${MEDIA_TYPE} schemaVersion=${SCHEMA_VERSION}" >&2

# Check if this is a manifest list / OCI image index (multi-arch)
IS_LIST="false"
if [[ "${MEDIA_TYPE}" == "application/vnd.oci.image.index.v1+json" ]] ||
   [[ "${MEDIA_TYPE}" == "application/vnd.docker.distribution.manifest.list.v2+json" ]]; then
    IS_LIST="true"
fi

if [[ "${IS_LIST}" == "true" ]]; then
    # Multi-arch image — check if arm64 platform entry exists
    ARCHITECTURES=$(echo "${RAW}" | jq -r '[.manifests[].platform.architecture] | unique | sort | join(", ")' 2>/dev/null)
    HAS_ARM64=$(echo "${RAW}" | jq '[.manifests[].platform.architecture] | any(. == "arm64")' 2>/dev/null)

    echo "Manifest list architectures: ${ARCHITECTURES}" >&2

    if [[ "${HAS_ARM64}" == "true" ]]; then
        jq -n --arg summary "arm64 build available (architectures: ${ARCHITECTURES})" \
            '{"affected":false,"summary":$summary,"severity":"info","hits":[],"implementation_spec":""}'
    else
        jq -n \
            --arg file "${IMAGE_REF}" \
            --arg match "architectures: ${ARCHITECTURES}" \
            --arg archs "${ARCHITECTURES}" \
            '{
                "affected": true,
                "summary": ("Multi-arch image missing arm64 build (has: " + $archs + ")"),
                "severity": "high",
                "hits": [
                    {
                        "file":        $file,
                        "line":        0,
                        "match":       $match,
                        "description": "This image is published as a multi-arch manifest list but does not include an arm64/aarch64 variant. Operators must provide arm64 builds to support ARM-based OpenShift clusters.",
                        "suggestion":  "Add an arm64/aarch64 build to the image build pipeline and publish it in the manifest list."
                    }
                ],
                "implementation_spec": ""
            }'
    fi
else
    # Single-platform manifest — inspect the image config to get architecture
    CONFIG=$(skopeo inspect --override-arch amd64 "docker://${IMAGE_REF}" 2>&1)
    CONFIG_EXIT=$?

    if [[ ${CONFIG_EXIT} -ne 0 ]]; then
        ERROR_MSG=$(echo "${CONFIG}" | head -3 | tr '"' "'" | tr '\n' ' ')
        jq -n --arg err "Error inspecting image config: ${ERROR_MSG}" \
            '{"affected":false,"summary":$err,"severity":"info","hits":[],"implementation_spec":""}'
        exit 0
    fi

    ARCH=$(echo "${CONFIG}" | jq -r '.Architecture // "unknown"' 2>/dev/null)
    echo "Single-platform manifest, architecture: ${ARCH}" >&2

    if [[ "${ARCH}" == "arm64" || "${ARCH}" == "aarch64" ]]; then
        jq -n --arg summary "Single-arch image is arm64 (no multi-arch manifest list)" \
            '{"affected":false,"summary":$summary,"severity":"info","hits":[],"implementation_spec":""}'
    else
        jq -n \
            --arg file "${IMAGE_REF}" \
            --arg match "architecture: ${ARCH}" \
            --arg arch "${ARCH}" \
            '{
                "affected": true,
                "summary": ("Single-arch image built for " + $arch + " only, no arm64/aarch64 build"),
                "severity": "high",
                "hits": [
                    {
                        "file":        $file,
                        "line":        0,
                        "match":       ("architecture: " + $arch),
                        "description": "This image is published as a single-architecture manifest with no arm64/aarch64 variant. Operators must provide arm64 builds to support ARM-based OpenShift clusters.",
                        "suggestion":  "Build and publish the image as a multi-arch manifest list that includes arm64/aarch64."
                    }
                ],
                "implementation_spec": ""
            }'
    fi
fi
