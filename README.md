# nixlbench on Kubernetes

Runs [nixlbench](https://github.com/ai-dynamo/nixl/tree/main/benchmark/nixlbench) in a Kubernetes
pod to measure bandwidth for **memory transfers between NUMA nodes**, **storage I/O**, and
**host memory to GPU** transfers.

## Run

```bash
./scripts/deploy-nixlbench.sh
```

Run this. Below is the output you will see in order; values depend on the cluster.

The pod requests one GPU. `nixlbench` links `libcuda.so.1`, so it does not start without one even
on a DRAM-only path. The GPU is not used for compute.

### Step 1. Existing pod check

Shown only if the pod already exists.

```
pod nixlbench-cxl already exists on node worker01.

Pod specs are immutable, so any manifest change (resources, volumes, nodeSelector)
needs a delete and recreate. Only the container image can be updated in place.

  [1] keep it, go straight to the benchmark
  [2] delete and recreate

select [1-2]:
```

Choose `2` if you changed the manifest, `1` to just rerun the benchmark.

### Step 2. Node selection

```
cluster nodes:
  NAME        STATUS   ROLES           AGE   VERSION   INTERNAL-IP    ...
  worker01    Ready    <none>          52d   v1.35.1   10.0.0.11      ...
  control01   Ready    control-plane   52d   v1.35.1   10.0.0.10      ...

  [1] worker01
  [2] control01

select node [1-2]: 1
node: worker01
```

Pick the node.

### Step 3. SSD mount path

```
SSD mount path: the directory the device is actually mounted on (check with lsblk).
A missing path is created, so a wrong path measures the root disk instead.
path [/mnt/nixlbench-data]: /mnt/nvme0
storage: /mnt/nvme0
```

Enter the path where the device is mounted.

### Step 4. Deploy and wait for Ready

```
pod/nixlbench-cxl created

waiting for nixlbench-cxl to become Ready...
  first pull on a node takes 5-10 min (the image is tens of GB); later runs are instant.
pod/nixlbench-cxl condition met

NAME            READY   STATUS    RESTARTS   AGE   IP            NODE       ...
nixlbench-cxl   1/1     Running   0          8s    10.233.95.60  worker01   ...
```

The image pull can take 5-10 minutes. If the image is already on the node it starts right away.

### Step 5. NUMA topology

```
NUMA topology inside the pod:
  available: 2 nodes (0-1)

  node 0
    cpus: 144  (0-71,144-215)
    size: 1159644 MB
    free: 793886 MB

  node 1
    cpus: 144  (72-143,216-287)
    size: 1161149 MB
    free: 885546 MB
```

Note the node numbers to choose from in the next step. `cpus: none` marks a CPU-less,
memory-only node (CXL).

### Step 6. Measurement mode

```
what to measure (source is always host memory):

  [1] memory -> memory   another NUMA node, e.g. CXL exposed as system-ram
                         UCX backend, two processes, buffers on different nodes
  [2] memory -> storage  a file on the NVMe mount, e.g. SSD
                         POSIX backend, one process
  [3] memory -> GPU      the GPU attached to the pod (DRAM -> VRAM)
                         UCX backend, two processes, target buffer in VRAM

select target [1-3]:

op: WRITE first, then READ.
```

Pick the mode. WRITE runs first, then READ, with the scenario you enter.

### Step 7. Scenario

```
scenario:
  block size sweep     1 MiB .. 16 MiB
                       transfer size per descriptor; nixlbench doubles it each step
                       and reports one row per size. This is the x-axis of the result.
  batch size           64
                       descriptors submitted together in one transfer request.
                       Larger batches keep the device queue deeper.
  threads              8
                       worker threads issuing transfers in parallel.
  buffer per process   8 GiB
                       memory each process allocates and binds to its NUMA node.
                       must be at least block_max * batch * threads
                       = 16 MiB * 64 * 8 = 8 GiB
  iterations           256 measured, 32 warmup (discarded)

run this scenario? [Y/n]:
```

Enter accepts. `n` prompts for each value. See [Scenario parameters](#scenario-parameters).

---

The flow now splits into A, B or C depending on Step 6.

## A. memory → memory

### A-1. Source and target node

```
NUMA nodes:
  [1] node 0   cpus: 144 (0-71,144-215)   free: 793886 MB
  [2] node 1   cpus: 144 (72-143,216-287)   free: 885546 MB

source node (initiator buffer, local DRAM) [1-2]: 1
source: node 0

NUMA nodes:
  [1] node 0   cpus: 144 (0-71,144-215)   free: 885546 MB
  [2] node 1   cpus: 144 (72-143,216-287)   free: 885546 MB

target node (e.g. the CXL node) [1-2]: 2
target: node 1
```

Pick the source and target nodes. Choosing the same node is the local baseline run.

```
note: both buffers are on node 0, so this is the LOCAL BASELINE run.
      For a DRAM -> CXL measurement, pick two different nodes.
      Keep this result: the cross-node number means nothing without it.
```

### A-2. Plan

```
plan:
  rank 0 (initiator)  DRAM on node 0
  rank 1 (target)     node 1
  both processes      numactl --cpunodebind=0
  backend             UCX (same host)
  op                  WRITE, then READ
  buffer              8589934592 bytes per process
  etcd                started inside the pod at http://127.0.0.1:2379

while this runs, verify placement from another shell:
  kubectl exec nixlbench-cxl -n default -- bash -c 'numastat -p $(pgrep -n nixlbench)'
  -> node 1 RSS should be close to the buffer size above

run it? [y/N]:
```

Check the plan and run with `y`.

### A-3. Run

```
starting etcd...

############################## op=WRITE ##############################
----------- WRITE rank 0 (initiator: DRAM node 0), live -----------
launching rank 0 on node 0...
launching rank 1 (target: node 1)...
WARNING: Adjusting warmup_iter to 128 to allow equal distribution to 8 threads
Connecting to ETCD at http://127.0.0.1:2379
ETCD Runtime: Registered as rank 0 item 1 of 2
Init nixl worker, dev all rank 0, type initiator, hostname nixlbench-cxl
...
Block Size (B)   Batch Size   B/W (GB/Sec)   Avg Lat. (us)   ...
1048576          64           105.774345     79.3            ...
2097152          64           105.129664     159.6           ...
4194304          64           104.780856     320.2           ...
8388608          64           100.111121     670.3           ...
16777216         64            97.411981     1377.8          ...

=========== WRITE rank 1 (target: node 1) ===========
...

WRITE exit codes: rank0=0 rank1=0

############################## op=READ ##############################
...
```

The rank 0 log streams live; the rank 1 log is printed when it finishes.
`UCX ERROR failed to get interface index for <nic>: No such device` can be ignored.

## B. memory → storage

### B-1. Target directory

```
nixlbench treats --filepath as a DIRECTORY and creates
nixlbench_posix_test_file_* inside it, so the directory must exist.

target directory (default: /mnt/nixlbench-data/nixlbench, Enter to keep):
target: /mnt/nixlbench-data/nixlbench
```

Enter the target directory. Enter keeps the default.

### B-2. Plan

```
plan:
  buffer      local DRAM (no numactl policy)
  target      /mnt/nixlbench-data/nixlbench
  backend     POSIX, io_uring, O_DIRECT
  op          WRITE, then READ
  buffer size 8589934592 bytes

run it? [y/N]:
```

Check the plan and run with `y`.

### B-3. Run

```
############################## op=WRITE ##############################
Creating file: /mnt/nixlbench-data/nixlbench/nixlbench_posix_test_file_initiator_0
...
Block Size (B)   Batch Size   B/W (GB/Sec)   Avg Lat. (us)   ...
...

############################## op=READ ##############################
...
```

Output appears directly on screen.

## C. memory → GPU

### C-1. Source node

```
NUMA nodes:
  [1] node 0   cpus: 144 (0-71,144-215)   free: 793916 MB
  [2] node 1   cpus: 144 (72-143,216-287)   free: 885478 MB

source node (initiator buffer, local DRAM) [1-2]: 1
source: node 0
```

Pick the source node. The target is the GPU attached to the pod.

### C-2. Plan

```
plan:
  rank 0 (initiator)  DRAM on node 0
  rank 1 (target)     GPU (VRAM)
  both processes      numactl --cpunodebind=0
  backend             UCX (same host)
  op                  WRITE, then READ
  buffer              8589934592 bytes per process
  etcd                started inside the pod at http://127.0.0.1:2379

run it? [y/N]:
```

Check the plan and run with `y`.

### C-3. Run

```
############################## op=WRITE ##############################
----------- WRITE rank 0 (initiator: DRAM node 0), live -----------
launching rank 0 on node 0...
launching rank 1 (target: GPU (VRAM))...
...
WRITE exit codes: rank0=0 rank1=0

############################## op=READ ##############################
----------- READ rank 0 (initiator: DRAM node 0), live -----------
...
Target seg type (--target_seg_type=[DRAM,VRAM])             : VRAM
Op type (--op_type=[READ,WRITE])                            : READ
...
Block Size (B)   Batch Size   B/W (GB/Sec)   Avg Lat. (us)   ...
1048576          64           36.366515      230.7           ...
2097152          64           36.753729      456.5           ...
4194304          64           36.891055      909.6           ...
8388608          64           37.258284      1801.2          ...
16777216         64           37.636937      3566.1          ...

=========== READ rank 1 (target: GPU (VRAM)) ===========
...

READ exit codes: rank0=0 rank1=0
done: WRITE and READ finished (exit 0)
```

The rank 0 log streams live; the rank 1 log is printed when it finishes.

## Scenario parameters

| Parameter | Default | Meaning |
|---|---|---|
| block size sweep | 1 MiB ~ 16 MiB | size of one transfer |
| batch size | 64 | descriptors submitted at once |
| threads | 8 | parallelism |
| buffer per process | 8 GiB | per-process buffer; must be at least `block_max × batch × threads` |
| iterations | 256 (+32 warmup) | measured repetitions |

## Flags

| Flag | Meaning |
|---|---|
| `--membind=N` | allocate memory only on node N |
| `--preferred=N` | prefer node N, fall back to others when full |
| `--cpunodebind=N` | run threads on node N's CPUs |
| `--initiator_seg_type DRAM` | put the initiator buffer in host memory |
| `--target_seg_type DRAM\|VRAM` | put the target buffer in host or GPU memory |
| `--filepath DIR` | directory where test files are created |
| `--posix_api_type URING` | use io_uring; `AIO` and `POSIXAIO` also work |
| `--storage_enable_direct` | bypass the page cache with O_DIRECT |
| `--posix_kernel_queue_size` | AIO/URING kernel queue depth |

## Cleanup

```bash
./scripts/deploy-nixlbench.sh --delete
```

To remove the test files as well, run `kubectl exec <pod> -- rm -rf <ssd_dir>` before deleting the pod.

## Notes

- `--membind` dies with OOM if the target node runs out of memory
- When you raise the buffer, raise the pod `limits.memory` with it
