# nixlbench on Kubernetes

[nixlbench](https://github.com/ai-dynamo/nixl/tree/main/benchmark/nixlbench) 를 Kubernetes pod에서
돌려 **NUMA 노드 간 메모리 전송**, **스토리지 I/O**, **호스트 메모리에서 GPU로의 전송** 대역폭을
측정합니다.

## 실행

```bash
./scripts/deploy-nixlbench.sh
```

이걸 실행시키면 됩니다. 아래는 순서대로 나오는 출력이고, 값은 클러스터에 따라 다릅니다.

pod은 GPU 1개를 할당받습니다. `nixlbench` 가 `libcuda.so.1` 에 링크되어 있어 DRAM 전용 경로라도
없으면 실행되지 않기 때문이고, 연산에는 쓰지 않습니다.

### Step 1. 기존 pod 확인

pod이 이미 있을 때만 나옵니다.

```
pod nixlbench-cxl already exists on node worker01.

Pod specs are immutable, so any manifest change (resources, volumes, nodeSelector)
needs a delete and recreate. Only the container image can be updated in place.

  [1] keep it, go straight to the benchmark
  [2] delete and recreate

select [1-2]:
```

매니페스트를 고쳤으면 `2`, 벤치만 다시 돌리면 `1` 을 고릅니다.

### Step 2. 노드 선택

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

노드를 고릅니다.

### Step 3. SSD 마운트 경로

```
SSD mount path: the directory the device is actually mounted on (check with lsblk).
A missing path is created, so a wrong path measures the root disk instead.
path [/mnt/nixlbench-data]: /mnt/nvme0
storage: /mnt/nvme0
```

디바이스가 마운트된 경로를 작성합니다.

### Step 4. 배포와 Ready 대기

```
pod/nixlbench-cxl created

waiting for nixlbench-cxl to become Ready...
  first pull on a node takes 5-10 min (the image is tens of GB); later runs are instant.
pod/nixlbench-cxl condition met

NAME            READY   STATUS    RESTARTS   AGE   IP            NODE       ...
nixlbench-cxl   1/1     Running   0          8s    10.233.95.60  worker01   ...
```

이미지 pull에 5~10분 걸릴 수 있습니다. 이미지가 있으면 바로 실행됩니다.

### Step 5. NUMA 토폴로지

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

다음 단계에서 고를 노드 번호를 확인합니다. `cpus: none` 은 CPU 없는 메모리 전용 노드(CXL)입니다.

### Step 6. 측정 모드 선택

```
what to measure (source is always host memory):

  [1] memory -> memory   another NUMA node, e.g. CXL exposed as system-ram
                         UCX backend, two processes, buffers on different nodes
  [2] memory -> storage  a file on the NVMe mount, e.g. SSD
                         POSIX backend, one process
  [3] memory -> GPU      the GPU attached to the pod (DRAM -> VRAM)
                         UCX backend, two processes, target buffer in VRAM

select target [1-3]:

op: WRITE 먼저 실행하고, 이어서 READ 를 진행하겠습니다.
```

측정 모드를 고릅니다. 입력한 시나리오에 맞게 WRITE, READ 를 순서대로 동작시킵니다.

### Step 7. 시나리오 확인

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

엔터는 수락, `n` 은 항목별 입력입니다. 파라미터 의미는 [시나리오 파라미터](#시나리오-파라미터) 참조.

---

Step 6의 선택에 따라 갈립니다. `[3]` 은 A와 같고 source 노드만 고릅니다.

## A. memory → memory

### A-1. source·target 노드 선택

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

source 노드와 target 노드를 고릅니다. 같은 노드를 고르면 로컬 기준값 실행입니다.

```
note: both buffers are on node 0, so this is the LOCAL BASELINE run.
      For a DRAM -> CXL measurement, pick two different nodes.
      Keep this result: the cross-node number means nothing without it.
```

### A-2. 실행 계획 확인

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

계획을 확인하고 `y` 로 실행합니다.

### A-3. 실행

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

rank 0 로그는 실시간으로, rank 1 로그는 종료 후 출력됩니다.
`UCX ERROR failed to get interface index for <nic>: No such device` 는 무시해도 됩니다.

## B. memory → storage

### B-1. 대상 디렉터리

```
nixlbench treats --filepath as a DIRECTORY and creates
nixlbench_posix_test_file_* inside it, so the directory must exist.

target directory (default: /mnt/nixlbench-data/nixlbench, 그대로 쓰려면 엔터):
target: /mnt/nixlbench-data/nixlbench
```

대상 디렉터리를 작성합니다. 엔터는 기본값입니다.

### B-2. 실행 계획 확인

```
plan:
  buffer      local DRAM (no numactl policy)
  target      /mnt/nixlbench-data/nixlbench
  backend     POSIX, io_uring, O_DIRECT
  op          WRITE, then READ
  buffer size 8589934592 bytes

run it? [y/N]:
```

### B-3. 실행

```
############################## op=WRITE ##############################
Creating file: /mnt/nixlbench-data/nixlbench/nixlbench_posix_test_file_initiator_0
...
Block Size (B)   Batch Size   B/W (GB/Sec)   Avg Lat. (us)   ...
...

############################## op=READ ##############################
...
```

출력이 바로 화면에 나옵니다.

## 시나리오 파라미터

| 파라미터 | 기본값 | 의미 |
|---|---|---|
| block size sweep | 1 MiB ~ 16 MiB | 전송 1건당 크기 |
| batch size | 64 | 한 번에 제출하는 descriptor 수 |
| threads | 8 | 병렬도 |
| buffer per process | 8 GiB | 프로세스당 버퍼. `block_max × batch × threads` 이상이어야 합니다 |
| iterations | 256 (+32 warmup) | 측정 반복 수 |

## 플래그별 설명

| 플래그 | 의미 |
|---|---|
| `--membind=N` | 메모리를 노드 N에만 할당합니다 |
| `--preferred=N` | 노드 N을 우선하고, 부족하면 다른 노드를 씁니다 |
| `--cpunodebind=N` | 스레드를 노드 N의 CPU에서 실행합니다 |
| `--initiator_seg_type DRAM` | initiator 버퍼를 호스트 메모리에 둡니다 |
| `--target_seg_type DRAM\|VRAM` | target 버퍼를 호스트 메모리 또는 GPU 메모리에 둡니다 |
| `--filepath DIR` | 테스트 파일을 만들 디렉터리입니다 |
| `--posix_api_type URING` | io_uring 을 씁니다. `AIO`, `POSIXAIO` 도 가능합니다 |
| `--storage_enable_direct` | O_DIRECT 로 페이지 캐시를 우회합니다 |
| `--posix_kernel_queue_size` | AIO/URING 커널 큐 깊이입니다 |

## 검증

실행 중에 다른 셸에서 아래 명령으로 확인합니다.

```bash
kubectl exec <pod> -- bash -c 'for p in $(pgrep nixlbench); do numastat -p $p | tail -5; done'
```

RSS 가 source 노드와 target 노드에 각각 잡혀 있으면 됩니다.

대조군은 같은 노드(source = target)로 한 번 더 돌려 비교합니다.

## 정리

```bash
./scripts/deploy-nixlbench.sh --delete
```

테스트 파일까지 지우려면 pod 삭제 전에 `kubectl exec <pod> -- rm -rf <ssd_dir>` 을 실행합니다.

## 주의사항

- `--membind` 은 대상 노드 용량이 부족하면 OOM 으로 죽습니다
- 버퍼를 키우면 pod `limits.memory` 도 같이 키웁니다
- `--use_hugepages` 는 쓰지 않습니다
