#!/bin/bash
# Build and publish the numactl-enabled nixlbench image.
#
# Overridable via environment:
#   BASE_IMAGE    upstream image to build on top of
#   TARGET_IMAGE  image to build and push
#   PUSH          set to 0 to build and verify without publishing

set -euo pipefail

# The base is the immutable local tag produced by nixl's own contrib/build.sh, not
# the published tag. Building FROM the tag we are about to overwrite would stack a
# fresh numactl layer on top of the previous result on every run.
BASE_IMAGE="${BASE_IMAGE:-nixlbench:v1.3.1.dev.d2495941}"
TARGET_IMAGE="${TARGET_IMAGE:-changhyeonnam/nixlbench:latest}"
PUSH="${PUSH:-1}"

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

echo "base:   ${BASE_IMAGE}"
echo "target: ${TARGET_IMAGE}"
echo

docker build \
    --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
    -f "${REPO_ROOT}/docker/Dockerfile" \
    -t "${TARGET_IMAGE}" \
    "${REPO_ROOT}/docker"

# Verify before publishing. A pushed image that silently lacks numactl is worse
# than a failed build, because the failure then surfaces inside the cluster.
echo
echo "--- numactl / numastat ---"
docker run --rm "${TARGET_IMAGE}" bash -c 'command -v numactl && command -v numastat'

echo
echo "--- nixlbench library resolution ---"
# Grep outside the container: the base image's ENTRYPOINT prints a CUDA banner to
# stdout before our command runs, so an in-container grep does not filter it.
#
# libcuda.so.1 is excluded on purpose. It ships with the NVIDIA driver and is
# injected at runtime by the container toolkit, so it is always unresolved when
# the image is inspected on a host without a GPU (e.g. the control-plane node).
missing=$(docker run --rm "${TARGET_IMAGE}" ldd /usr/local/nixlbench/bin/nixlbench \
    | grep "not found" | grep -v "libcuda\.so\.1" || true)
if [ -n "${missing}" ]; then
    echo "ERROR: nixlbench has unresolved libraries:" >&2
    echo "${missing}" >&2
    exit 1
fi
echo "ok (no unresolved libraries other than driver-provided libcuda.so.1)"

if [ "${PUSH}" != "1" ]; then
    echo
    echo "PUSH=0, skipping push. Image available locally as ${TARGET_IMAGE}"
    exit 0
fi

echo
docker push "${TARGET_IMAGE}"
