#!/bin/bash
# Pick what to measure, then run nixlbench inside the workbench pod.
#
# Two shapes of run, because nixlbench moves data between two endpoints and the
# endpoint kinds decide the backend:
#
#   memory -> memory   UCX backend, two processes on the same host. Each process
#                      gets its own numactl policy, so the initiator buffer and the
#                      target buffer land on different NUMA nodes. This is how a
#                      DRAM -> CXL transfer is measured when CXL is exposed as
#                      system-ram. Ranks come from etcd registration order
#                      (first to register is rank 0 = initiator), so the target is
#                      started a couple of seconds later.
#
#   memory -> file     POSIX backend, one process. The buffer sits on local DRAM
#                      and the target is a file on the mounted block device.
#
# Overridable via environment:
#   POD_NAME, NAMESPACE, SSD_DIR, TOTAL_BUFFER_SIZE, NUM_ITER, WARMUP_ITER, NUM_THREADS

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# Per-testbed values live in config.sh, which is gitignored so each machine keeps
# its own. It assigns with ${VAR:-...} so anything already in the environment wins.
if [ -f "${REPO_ROOT}/config.sh" ]; then
    # shellcheck source=/dev/null
    . "${REPO_ROOT}/config.sh"
fi

POD_NAME="${POD_NAME:-nixlbench-cxl}"
NAMESPACE="${NAMESPACE:-default}"
# Derive the storage target from the pod's actual mount rather than a constant, so
# it follows HOST_PATH and manifest edits without a second place to update.
if [ -z "${SSD_DIR:-}" ]; then
    mount_path=$(kubectl get pod "${POD_NAME:-nixlbench-cxl}" -n "${NAMESPACE:-default}" \
        -o jsonpath='{.spec.containers[0].volumeMounts[?(@.name=="nvme")].mountPath}' 2>/dev/null)
    SSD_DIR="${mount_path:-/mnt/nixlbench-data}/nixlbench"
fi
# nixlbench requires max_block_size * max_batch_size <= total_buffer_size / num_threads.
# 8 GiB is the smallest value that satisfies it for the block/batch/thread defaults
# below, and it is also nixlbench's own default.
TOTAL_BUFFER_SIZE="${TOTAL_BUFFER_SIZE:-8589934592}"
BLOCK_MIN="${BLOCK_MIN:-1048576}"
BLOCK_MAX="${BLOCK_MAX:-16777216}"
BATCH_SIZE="${BATCH_SIZE:-64}"
NUM_ITER="${NUM_ITER:-256}"
WARMUP_ITER="${WARMUP_ITER:-32}"
NUM_THREADS="${NUM_THREADS:-8}"
ETCD_ENDPOINT="http://127.0.0.1:2379"

kx() { kubectl exec "${POD_NAME}" -n "${NAMESPACE}" -- "$@"; }

# Ctrl+C kills kubectl here, but not the benchmark in the pod: the ranks write to
# log files rather than the exec stream, so they never see EPIPE and get reparented
# to PID 1 still holding GiBs of bound memory. Reach back in and stop them.
cleanup_remote() {
    echo
    echo "interrupted -- stopping nixlbench in the pod..."
    kubectl exec "${POD_NAME}" -n "${NAMESPACE}" -- \
        pkill -f '[n]ixlbench' >/dev/null 2>&1 || true
    exit 130
}
trap cleanup_remote INT TERM

# Render a byte count the way a person reads it, so a wrong order of magnitude in
# the scenario is obvious before the run rather than after.
human() {
    local b="$1"
    if   [ "${b}" -ge 1073741824 ]; then printf '%s GiB' "$((b / 1073741824))"
    elif [ "${b}" -ge 1048576 ];    then printf '%s MiB' "$((b / 1048576))"
    elif [ "${b}" -ge 1024 ];       then printf '%s KiB' "$((b / 1024))"
    else                                 printf '%s B' "${b}"
    fi
}

# read -p writes its prompt to stderr, so this is safe in a command substitution.
ask() {
    local label="$1" current="$2" answer
    read -r -p "  ${label} [${current}]: " answer </dev/tty
    printf '%s' "${answer:-${current}}"
}

describe_scenario() {
    cat <<EOF

scenario:
  block size sweep     $(human "${BLOCK_MIN}") .. $(human "${BLOCK_MAX}")
                       transfer size per descriptor; nixlbench doubles it each step
                       and reports one row per size. This is the x-axis of the result.
  batch size           ${BATCH_SIZE}
                       descriptors submitted together in one transfer request.
                       Larger batches keep the device queue deeper.
  threads              ${NUM_THREADS}
                       worker threads issuing transfers in parallel.
  buffer per process   $(human "${TOTAL_BUFFER_SIZE}")
                       memory each process allocates and binds to its NUMA node.
                       must be at least block_max * batch * threads
                       = $(human "${BLOCK_MAX}") * ${BATCH_SIZE} * ${NUM_THREADS} = $(human "$((BLOCK_MAX * BATCH_SIZE * NUM_THREADS))")
  iterations           ${NUM_ITER} measured, ${WARMUP_ITER} warmup (discarded)
EOF
}

# nixlbench rejects the run late, after both ranks have registered with etcd, so
# check the same arithmetic up front and offer the fix.
validate_scenario() {
    local required=$((BLOCK_MAX * BATCH_SIZE * NUM_THREADS)) answer
    [ "${TOTAL_BUFFER_SIZE}" -ge "${required}" ] && return 0

    cat >&2 <<EOF

buffer too small for this scenario:
  max_block_size * max_batch_size  = $(human "$((BLOCK_MAX * BATCH_SIZE))")
  total_buffer_size / num_threads  = $(human "$((TOTAL_BUFFER_SIZE / NUM_THREADS))")
nixlbench requires the first to be no larger than the second, so the buffer needs
to be at least $(human "${required}") ($(human "${BLOCK_MAX}") * ${BATCH_SIZE} * ${NUM_THREADS}).

EOF
    read -r -p "raise buffer to $(human "${required}")? [Y/n]: " answer
    case "${answer}" in
        n|N) echo "aborted. lower block size, batch size or threads instead." >&2; exit 1 ;;
        *)   TOTAL_BUFFER_SIZE="${required}"
             echo "buffer per process: $(human "${TOTAL_BUFFER_SIZE}")"
             echo ;;
    esac
}

tune_scenario() {
    local answer
    read -r -p "run this scenario? [Y/n]: " answer
    case "${answer}" in
        n|N)
            echo
            echo "enter new values, or press Enter to keep the current one:"
            BLOCK_MIN=$(ask "block size min (bytes)" "${BLOCK_MIN}")
            BLOCK_MAX=$(ask "block size max (bytes)" "${BLOCK_MAX}")
            BATCH_SIZE=$(ask "batch size" "${BATCH_SIZE}")
            NUM_THREADS=$(ask "threads" "${NUM_THREADS}")
            TOTAL_BUFFER_SIZE=$(ask "buffer per process (bytes)" "${TOTAL_BUFFER_SIZE}")
            NUM_ITER=$(ask "measured iterations" "${NUM_ITER}")
            WARMUP_ITER=$(ask "warmup iterations" "${WARMUP_ITER}")
            if [ "${BLOCK_MAX}" -lt "${BLOCK_MIN}" ]; then
                echo "ERROR: block size max is below min" >&2
                exit 1
            fi
            describe_scenario
            echo
            ;;
    esac
}

if [ ! -t 0 ]; then
    echo "ERROR: this script prompts for choices and needs a terminal." >&2
    exit 1
fi

# ---------------------------------------------------------------- target kind

cat <<'EOF'
what to measure (source is always host memory):

  [1] memory -> memory   another NUMA node, e.g. CXL exposed as system-ram
                         UCX backend, two processes, buffers on different nodes
  [2] memory -> storage  a file on the NVMe mount, e.g. SSD
                         POSIX backend, one process
  [3] memory -> GPU      the GPU attached to the pod (DRAM -> VRAM)
                         UCX backend, two processes, target buffer in VRAM

EOF
read -r -p "select target [1-3]: " target_kind
case "${target_kind}" in
    1|2|3) ;;
    *) echo "ERROR: invalid selection '${target_kind}'" >&2; exit 1 ;;
esac
echo

# --------------------------------------------------------------- op direction

# Both directions always run, WRITE first: on the storage path that leaves the
# target file populated before READ reads it, and having the pair side by side is
# what makes a result interpretable.
echo "op: WRITE 먼저 실행하고, 이어서 READ 를 진행하겠습니다."

describe_scenario
echo
tune_scenario
validate_scenario
echo

# ------------------------------------------------------------------ node menu

list_numa_nodes() {
    kx numactl --hardware 2>/dev/null | awk -f "${REPO_ROOT}/scripts/lib/numa.awk"
}

pick_node() {
    # $1 = prompt label. Writes the chosen node id to stdout, menu to stderr.
    local label="$1" i=0 nd ncpu rng size free
    local -a ids=()

    {
        echo "NUMA nodes:"
        while IFS=$'\t' read -r nd ncpu rng size free; do
            i=$((i + 1))
            ids+=("${nd}")
            if [ "${ncpu}" -eq 0 ]; then
                printf '  [%d] node %s   cpus: none (memory-only)   free: %s\n' \
                    "${i}" "${nd}" "${free}"
            else
                printf '  [%d] node %s   cpus: %s (%s)   free: %s\n' \
                    "${i}" "${nd}" "${ncpu}" "${rng}" "${free}"
            fi
        done < <(list_numa_nodes)
        echo
    } >&2

    if [ "${#ids[@]}" -eq 0 ]; then
        echo "ERROR: could not read NUMA topology from the pod" >&2
        exit 1
    fi

    local choice
    read -r -p "${label} [1-${#ids[@]}]: " choice </dev/tty
    if ! [[ "${choice}" =~ ^[0-9]+$ ]] \
        || [ "${choice}" -lt 1 ] || [ "${choice}" -gt "${#ids[@]}" ]; then
        echo "ERROR: invalid selection '${choice}'" >&2
        exit 1
    fi
    printf '%s' "${ids[$((choice - 1))]}"
}

# ==================================================== memory -> memory, or GPU

if [ "${target_kind}" = "1" ] || [ "${target_kind}" = "3" ]; then
    src_node=$(pick_node "source node (initiator buffer, local DRAM)")
    echo "source: node ${src_node}"
    echo

    if [ "${target_kind}" = "3" ]; then
        # The target buffer lives in VRAM on the GPU attached to the pod, so there is
        # no second NUMA node to choose. The source node still matters: it decides
        # how far the host buffer sits from the GPU's PCIe root complex.
        target_seg="VRAM"
        dst_node="${src_node}"
        target_label="GPU (VRAM)"
    else
        target_seg="DRAM"
        dst_node=$(pick_node "target node (e.g. the CXL node)")
        echo "target: node ${dst_node}"
        echo
        target_label="node ${dst_node}"

        # Same node is allowed on purpose: it is the local baseline the cross-node
        # number has to be compared against. Without it there is no way to tell
        # whether a result is slow.
        if [ "${src_node}" = "${dst_node}" ]; then
            echo "note: both buffers are on node ${src_node}, so this is the LOCAL BASELINE run."
            echo "      For a DRAM -> CXL measurement, pick two different nodes."
            echo "      Keep this result: the cross-node number means nothing without it."
            echo
        fi
    fi

    # Threads stay on the source node for both processes so that memory placement
    # is the only difference between them.
    cpu_node="${src_node}"

    common_args="--etcd_endpoints ${ETCD_ENDPOINT} --backend UCX \
--initiator_seg_type DRAM --target_seg_type ${target_seg} \
--total_buffer_size ${TOTAL_BUFFER_SIZE} \
--start_block_size ${BLOCK_MIN} --max_block_size ${BLOCK_MAX} \
--start_batch_size ${BATCH_SIZE} --max_batch_size ${BATCH_SIZE} \
--num_threads ${NUM_THREADS} \
--num_iter ${NUM_ITER} --warmup_iter ${WARMUP_ITER}"

    cat <<EOF
plan:
  rank 0 (initiator)  DRAM on node ${src_node}
  rank 1 (target)     ${target_label}
  both processes      numactl --cpunodebind=${cpu_node}
  backend             UCX (same host)
  op                  WRITE, then READ
  buffer              ${TOTAL_BUFFER_SIZE} bytes per process
  etcd                started inside the pod at ${ETCD_ENDPOINT}

EOF
    read -r -p "run it? [y/N]: " go
    [ "${go}" = "y" ] || [ "${go}" = "Y" ] || { echo "aborted."; exit 0; }
    echo

    kubectl exec -i "${POD_NAME}" -n "${NAMESPACE}" -- bash -s <<EOF
set -u

# etcd ships in the image. Start it only if nothing is listening yet, so repeat
# runs reuse the same instance.
if ! etcdctl --endpoints=${ETCD_ENDPOINT} endpoint health >/dev/null 2>&1; then
    echo "starting etcd..."
    rm -rf /tmp/nixlbench-etcd
    etcd --data-dir /tmp/nixlbench-etcd \
         --listen-client-urls http://0.0.0.0:2379 \
         --advertise-client-urls ${ETCD_ENDPOINT} \
         --listen-peer-urls http://127.0.0.1:2380 \
         --initial-advertise-peer-urls http://127.0.0.1:2380 \
         --initial-cluster default=http://127.0.0.1:2380 \
         >/tmp/nixlbench-etcd.log 2>&1 &
    for i in \$(seq 30); do
        etcdctl --endpoints=${ETCD_ENDPOINT} endpoint health >/dev/null 2>&1 && break
        sleep 1
    done
fi

overall=0
for op in WRITE READ; do
    echo
    echo "############################## op=\$op ##############################"

    # An interrupted run leaves both nixlbench processes alive: their stdout goes to
    # log files rather than the exec stream, so they never see EPIPE and are simply
    # reparented to PID 1 when the shell dies. A survivor holds GiBs of bound memory
    # and shows up in etcd as a phantom peer, so clear processes and rank keys before
    # every pair.
    if pkill -f '[n]ixlbench --etcd_endpoints' 2>/dev/null; then
        echo "killed leftover nixlbench processes from an earlier run"
        sleep 1
    fi
    ETCDCTL_API=3 etcdctl --endpoints=${ETCD_ENDPOINT} del "xferbench" --prefix=true >/dev/null 2>&1 || true

    # Both ranks writing to one terminal interleaves into nonsense, so each gets its
    # own log. rank 0 is the initiator and prints the results, so follow its log live
    # rather than waiting minutes with a silent screen. Following the file instead of
    # piping through tee keeps \$? attached to nixlbench rather than to the pipeline.
    : >/tmp/nb-rank0-\$op.log
    echo "----------- \$op rank 0 (initiator: DRAM node ${src_node}), live -----------"
    tail -f /tmp/nb-rank0-\$op.log &
    tailer=\$!

    echo "launching rank 0 on node ${src_node}..."
    numactl --membind=${src_node} --cpunodebind=${cpu_node} \
        nixlbench ${common_args} --op_type \$op >/tmp/nb-rank0-\$op.log 2>&1 &
    rank0=\$!

    sleep 2

    echo "launching rank 1 (target: ${target_label})..."
    numactl --membind=${dst_node} --cpunodebind=${cpu_node} \
        nixlbench ${common_args} --op_type \$op >/tmp/nb-rank1-\$op.log 2>&1 &
    rank1=\$!

    wait \$rank0; rc0=\$?
    wait \$rank1; rc1=\$?

    sleep 1
    kill \$tailer 2>/dev/null || true
    wait \$tailer 2>/dev/null || true

    echo
    echo "=========== \$op rank 1 (target: ${target_label}) ==========="
    cat /tmp/nb-rank1-\$op.log

    echo
    echo "\$op exit codes: rank0=\$rc0 rank1=\$rc1"
    [ \$rc0 -eq 0 ] && [ \$rc1 -eq 0 ] || overall=1
done

echo
echo "done: WRITE and READ finished (exit \$overall)"
exit \$overall
EOF

# =========================================================== memory -> storage

else
    echo "nixlbench treats --filepath as a DIRECTORY and creates"
    echo "nixlbench_posix_test_file_* inside it, so the directory must exist."
    echo
    read -r -p "target directory (default: ${SSD_DIR}, 그대로 쓰려면 엔터): " answer
    run_dir="${answer:-${SSD_DIR}}"
    echo "target: ${run_dir}"
    echo

    cat <<EOF
plan:
  buffer      local DRAM (no numactl policy)
  target      ${run_dir}
  backend     POSIX, io_uring, O_DIRECT
  op          WRITE, then READ
  buffer size ${TOTAL_BUFFER_SIZE} bytes

EOF
    read -r -p "run it? [y/N]: " go
    [ "${go}" = "y" ] || [ "${go}" = "Y" ] || { echo "aborted."; exit 0; }
    echo

    kx mkdir -p "${run_dir}"

    overall=0
    for op in WRITE READ; do
        echo
        echo "############################## op=${op} ##############################"
        if kubectl exec -it "${POD_NAME}" -n "${NAMESPACE}" -- \
            nixlbench \
                --backend POSIX \
                --filepath "${run_dir}" \
                --initiator_seg_type DRAM \
                --op_type "${op}" \
                --posix_api_type URING \
                --storage_enable_direct \
                --total_buffer_size "${TOTAL_BUFFER_SIZE}" \
                --start_block_size "${BLOCK_MIN}" --max_block_size "${BLOCK_MAX}" \
                --start_batch_size "${BATCH_SIZE}" --max_batch_size "${BATCH_SIZE}" \
                --num_threads "${NUM_THREADS}" \
                --posix_kernel_queue_size 1024 \
                --num_iter "${NUM_ITER}" --warmup_iter "${WARMUP_ITER}"; then
            :
        else
            echo "${op} run failed" >&2
            overall=1
        fi
    done
    echo
    echo "done: WRITE and READ finished (exit ${overall})"
    exit "${overall}"
fi
