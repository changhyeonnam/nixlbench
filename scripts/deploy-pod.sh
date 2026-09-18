#!/bin/bash
# Deploy (or remove) the nixlbench workbench pod in the default namespace.
#
#   ./scripts/deploy-pod.sh              deploy and wait for Ready
#   ./scripts/deploy-pod.sh --delete     remove the pod
#
# Overridable via environment:
#   POD_NAME, NAMESPACE, NODE, IMAGE, HOST_PATH

set -euo pipefail

POD_NAME="${POD_NAME:-nixlbench-cxl}"
NAMESPACE="${NAMESPACE:-default}"
NODE="${NODE:-}"
IMAGE="${IMAGE:-}"
HOST_PATH="${HOST_PATH:-}"

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MANIFEST="${REPO_ROOT}/k8s/nixlbench-pod.yaml"

if [ "${1:-}" = "--delete" ]; then
    kubectl delete pod "${POD_NAME}" -n "${NAMESPACE}" --ignore-not-found
    exit 0
fi

rendered=$(cat "${MANIFEST}")
if [ -n "${NODE}" ]; then
    rendered=$(printf '%s\n' "${rendered}" \
        | sed "s|kubernetes.io/hostname: .*|kubernetes.io/hostname: ${NODE}|")
fi
if [ -n "${IMAGE}" ]; then
    rendered=$(printf '%s\n' "${rendered}" | sed "s|^      image: .*|      image: ${IMAGE}|")
fi
if [ -n "${HOST_PATH}" ]; then
    rendered=$(printf '%s\n' "${rendered}" | sed "s|/mnt/nvme-gpu1|${HOST_PATH}|g")
fi

printf '%s\n' "${rendered}" | kubectl apply -f -

echo
echo "waiting for ${POD_NAME} to become Ready (image pull can take a while on first run)..."
kubectl wait --for=condition=Ready "pod/${POD_NAME}" -n "${NAMESPACE}" --timeout=900s

echo
kubectl get pod "${POD_NAME}" -n "${NAMESPACE}" -o wide

cat <<EOF

next steps:
  ./scripts/preflight.sh                                  # verify NUMA / cpuset / io_uring / O_DIRECT
  ./scripts/bench-cxl.sh                                  # run the CXL-bound benchmark
  kubectl exec -it ${POD_NAME} -n ${NAMESPACE} -- bash     # poke around by hand
EOF
