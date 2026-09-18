#!/bin/bash
# Deploy (or remove) the nixlbench workbench pod in the default namespace.
#
#   ./scripts/deploy-nixlbench.sh              pick a node interactively, deploy, wait for Ready
#   NODE=<node> ./scripts/deploy-nixlbench.sh  skip the prompt and use that node
#   ./scripts/deploy-nixlbench.sh --delete     remove the pod
#
# Overridable via environment:
#   POD_NAME, NAMESPACE, NODE, IMAGE, HOST_PATH

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MANIFEST="${REPO_ROOT}/k8s/nixlbench-pod.yaml"

# Per-testbed values live in config.sh, which is gitignored so each machine keeps
# its own. It assigns with ${VAR:-...} so anything already in the environment wins.
if [ -f "${REPO_ROOT}/config.sh" ]; then
    # shellcheck source=/dev/null
    . "${REPO_ROOT}/config.sh"
fi

POD_NAME="${POD_NAME:-nixlbench-cxl}"
NAMESPACE="${NAMESPACE:-default}"
NODE="${NODE:-}"
IMAGE="${IMAGE:-}"
HOST_PATH="${HOST_PATH:-}"

if [ "${1:-}" = "--delete" ]; then
    kubectl delete pod "${POD_NAME}" -n "${NAMESPACE}" --ignore-not-found
    exit 0
fi

# Almost every Pod field is immutable, so `kubectl apply` over a running pod fails
# on any manifest change beyond the container image. Deal with that here instead of
# letting kubectl print its wall of nulls.
reuse_existing=0
if kubectl get pod "${POD_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
    if [ ! -t 0 ]; then
        echo "ERROR: pod ${POD_NAME} already exists and stdin is not a terminal." >&2
        echo "       Run './scripts/deploy-nixlbench.sh --delete' first." >&2
        exit 1
    fi
    cat <<EOF
pod ${POD_NAME} already exists on node $(kubectl get pod "${POD_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.nodeName}').

Pod specs are immutable, so any manifest change (resources, volumes, nodeSelector)
needs a delete and recreate. Only the container image can be updated in place.

  [1] keep it, go straight to the benchmark
  [2] delete and recreate

EOF
    read -r -p "select [1-2]: " existing_choice
    case "${existing_choice}" in
        1) reuse_existing=1 ;;
        2) echo; kubectl delete pod "${POD_NAME}" -n "${NAMESPACE}" ;;
        *) echo "ERROR: invalid selection '${existing_choice}'" >&2; exit 1 ;;
    esac
    echo
fi

if [ "${reuse_existing}" = "0" ] && [ -z "${NODE}" ]; then
    echo "cluster nodes:"
    kubectl get nodes -o wide | sed 's/^/  /'
    echo

    mapfile -t node_names < <(kubectl get nodes \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
    if [ "${#node_names[@]}" -eq 0 ]; then
        echo "ERROR: kubectl returned no nodes" >&2
        exit 1
    fi

    for i in "${!node_names[@]}"; do
        printf '  [%d] %s\n' "$((i + 1))" "${node_names[i]}"
    done
    echo

    if [ ! -t 0 ]; then
        echo "ERROR: NODE is unset and stdin is not a terminal." >&2
        echo "       Re-run with NODE=<name> to deploy without the prompt." >&2
        exit 1
    fi

    # No default: the right node differs per testbed, so the choice is always explicit.
    read -r -p "select node [1-${#node_names[@]}]: " choice
    if ! [[ "${choice}" =~ ^[0-9]+$ ]] \
        || [ "${choice}" -lt 1 ] || [ "${choice}" -gt "${#node_names[@]}" ]; then
        echo "ERROR: invalid selection '${choice}'" >&2
        exit 1
    fi

    NODE="${node_names[$((choice - 1))]}"
    echo "node: ${NODE}"
    echo
fi

# kubectl cannot read a node's mount table, so the path has to be typed. The
# manifest uses type: DirectoryOrCreate, so a missing path is created rather than
# blocking the pod. That means a typo yields an empty directory on the node's root
# filesystem, which a storage run would measure while looking healthy -- the Ready
# pod is not evidence that the right device is mounted.
if [ "${reuse_existing}" = "0" ] && [ -z "${HOST_PATH}" ] && [ -t 0 ]; then
    manifest_path=$(sed -n 's|^ *path: \(.*\)|\1|p' "${MANIFEST}" | head -1)

    echo "SSD mount path: the directory the device is actually mounted on (check with lsblk)."
    echo "A missing path is created, so a wrong path measures the root disk instead."
    read -r -p "path [${manifest_path}]: " answer
    HOST_PATH="${answer:-${manifest_path}}"
    echo "storage: ${HOST_PATH}"
    echo
fi

if [ "${reuse_existing}" = "0" ]; then
    rendered=$(cat "${MANIFEST}")
    if [ -n "${NODE}" ]; then
        rendered=$(printf '%s\n' "${rendered}" \
            | sed "s|kubernetes.io/hostname: .*|kubernetes.io/hostname: ${NODE}|")
    fi
    if [ -n "${IMAGE}" ]; then
        rendered=$(printf '%s\n' "${rendered}" | sed "s|^      image: .*|      image: ${IMAGE}|")
    fi
    if [ -n "${HOST_PATH}" ]; then
        # Swap whatever path the manifest currently carries, so this keeps working
        # after someone edits the manifest default.
        current_path=$(sed -n 's|^ *path: \(.*\)|\1|p' "${MANIFEST}" | head -1)
        rendered=$(printf '%s\n' "${rendered}" | sed "s|${current_path}|${HOST_PATH}|g")
    fi
    printf '%s\n' "${rendered}" | kubectl apply -f -
    echo
fi

echo "waiting for ${POD_NAME} to become Ready..."
echo "  first pull on a node takes 5-10 min (the image is tens of GB); later runs are instant."

# A pod that cannot mount its hostPath sits in ContainerCreating and looks exactly
# like a slow image pull, so waiting out the full timeout hides the cause. Show the
# events when the wait fails rather than leaving that to the reader.
if ! kubectl wait --for=condition=Ready "pod/${POD_NAME}" -n "${NAMESPACE}" --timeout=900s; then
    echo
    echo "pod did not become Ready. recent events:"
    kubectl describe pod "${POD_NAME}" -n "${NAMESPACE}" \
        | sed -n '/^Events:/,$p' | sed 's/^/  /'
    cat <<EOF

  A hostPath that does not exist on the node is the usual cause: the manifest uses
  type: Directory so the device mount has to exist already, on purpose. Point
  HOST_PATH at the mount you mean to measure (in config.sh or inline) and recreate:

    HOST_PATH=<mount point> ./scripts/deploy-nixlbench.sh --delete
    HOST_PATH=<mount point> ./scripts/deploy-nixlbench.sh

  Only the mount itself has to pre-exist; the directory the test files go into is
  created inside the pod at run time.
EOF
    exit 1
fi

echo
kubectl get pod "${POD_NAME}" -n "${NAMESPACE}" -o wide

# Report the NUMA layout straight away: it decides which node numbers the
# benchmark can bind to, and it doubles as proof that this is the numactl-enabled
# image rather than the upstream one.
echo
echo "NUMA topology inside the pod:"
if numa_out=$(kubectl exec "${POD_NAME}" -n "${NAMESPACE}" -- numactl --hardware 2>&1); then
    # numactl prints every cpu id on one line, which buries the numbers that matter
    # under a few hundred integers. The distance matrix is left out on purpose: it is
    # a firmware-declared hint that never changes between deploys, so check it by hand
    # (kubectl exec <pod> -- numactl --hardware) when it actually matters.
    printf '%s\n' "${numa_out}" | grep '^available:' | sed 's/^/  /'
    while IFS=$'\t' read -r nd ncpu rng size free; do
        echo
        echo "  node ${nd}"
        if [ "${ncpu}" -eq 0 ]; then
            echo "    cpus: none  <- memory-only node"
        else
            echo "    cpus: ${ncpu}  (${rng})"
        fi
        echo "    size: ${size}"
        echo "    free: ${free}"
    done < <(printf '%s\n' "${numa_out}" | awk -f "${REPO_ROOT}/scripts/lib/numa.awk")
else
    printf '%s\n' "${numa_out}" | sed 's/^/  /'
    cat <<'HINT'

  numactl failed. If that is "command not found", this pod is running an image
  without the numactl package -- check the image in k8s/nixlbench-pod.yaml. A
  running pod never re-pulls, so after fixing it:

    ./scripts/deploy-nixlbench.sh --delete && ./scripts/deploy-nixlbench.sh
HINT
fi

# Flow straight into target selection so one invocation goes from an empty cluster
# to a running benchmark. SKIP_BENCH=1 stops after the pod is up.
if [ "${SKIP_BENCH:-0}" = "1" ] || [ ! -t 0 ]; then
    cat <<EOF

pod is ready. to run a benchmark, re-run this script and keep the existing pod:
  ./scripts/deploy-nixlbench.sh
  kubectl exec -it ${POD_NAME} -n ${NAMESPACE} -- bash     # poke around by hand
EOF
    exit 0
fi

echo
echo "------------------------------------------------------------"
export POD_NAME NAMESPACE
exec "${REPO_ROOT}/scripts/run-bench.sh"
