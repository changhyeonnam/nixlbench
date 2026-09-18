# nixlbench on Kubernetes

[nixlbench](https://github.com/ai-dynamo/nixl/tree/main/benchmark/nixlbench) 를 Kubernetes pod에서
돌려 **NUMA 노드 간 메모리 전송**, **스토리지 I/O**, **호스트 메모리에서 GPU로의 전송** 대역폭을
측정한다.

## 실행

```bash
./scripts/deploy-nixlbench.sh
```

명령은 이것 하나다. 아래는 실행하면 순서대로 나오는 출력이고, 값은 클러스터에 따라 다르다.

pod은 GPU 1개를 할당받는다. `nixlbench` 가 `libcuda.so.1` 에 링크되어 있어 DRAM 전용 경로라도
없으면 실행되지 않기 때문이고, 연산에는 쓰지 않는다.

### Step 1. 기존 pod 확인

pod이 이미 있을 때만 나온다.

```
pod nixlbench-cxl already exists on node worker01.

Pod specs are immutable, so any manifest change (resources, volumes, nodeSelector)
needs a delete and recreate. Only the container image can be updated in place.

  [1] keep it, go straight to the benchmark
  [2] delete and recreate

select [1-2]:
```

매니페스트를 고쳤으면 **`2`**. 벤치만 다시 돌릴 때는 `1` 을 고르면 Step 5로 건너뛴다.

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

**기본값을 제시하지 않는다.** 맞는 노드는 테스트베드마다 다르고, 잘못 고르면 엉뚱한 하드웨어를
조용히 측정하게 된다. `NODE=worker01` 을 주면 이 프롬프트를 건너뛴다.

### Step 3. SSD 마운트 경로

```
SSD mount path: the directory the device is actually mounted on (check with lsblk).
A missing path is created, so a wrong path measures the root disk instead.
path [/mnt/nixlbench-data]: /mnt/nvme0
storage: /mnt/nvme0
```

**디바이스가 실제로 마운트된 디렉터리를 적어야 동작한다** (`lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS`
로 확인). 없는 경로는 만들어지므로, 잘못 적으면 pod은 정상적으로 뜨고 루트 디스크를 측정한다.
`HOST_PATH` 를 주면 이 프롬프트를 건너뛴다.

### Step 4. 배포와 Ready 대기

```
pod/nixlbench-cxl created

waiting for nixlbench-cxl to become Ready...
  first pull on a node takes 5-10 min (the image is tens of GB); later runs are instant.
pod/nixlbench-cxl condition met

NAME            READY   STATUS    RESTARTS   AGE   IP            NODE       ...
nixlbench-cxl   1/1     Running   0          8s    10.233.95.60  worker01   ...
```

이미지 pull에 **5~10분** 걸릴 수 있다. 노드에 이미 이미지가 있으면 바로 실행된다.

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

두 가지를 동시에 확인하는 단계다:

- **다음 단계에서 고를 노드 번호**가 여기서 나온다. `cpus: none` 으로 표시되는 노드는 CPU 없는
  메모리 전용 노드이며, CXL을 `system-ram` 으로 노출하면 그렇게 보인다
- **이미지가 맞는지.** `numactl` 이 없는 이미지면 이 단계에서 실패한다

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

**WRITE와 READ를 항상 연달아** 돌린다. storage 모드에서는 WRITE가 파일을 채워두므로 READ가
읽을 데이터가 생긴다.

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

엔터는 수락. `n` 이면 항목별로 물어보고 엔터는 현재값 유지다. 각 파라미터의 의미는
[시나리오 파라미터](#시나리오-파라미터) 참조.

버퍼가 제약(`block_max × batch × threads`)에 미달하면 여기서 잡아 올릴지 물어본다. nixlbench
자신은 etcd 랑데뷰까지 다 끝낸 뒤에야 거부하므로, 그때 실패하면 원인을 찾기 번거롭다.

---

여기서 Step 6의 선택에 따라 갈린다. `[3]` 은 아래 A와 같은 경로를 쓰고, **노드를 하나만 고르고
target 버퍼가 VRAM이 되는 점**만 다르다 (`--target_seg_type VRAM`). 그래도 source 노드는
의미가 있다. 그 호스트 버퍼가 GPU의 PCIe root complex에서 얼마나 먼지를 결정하기 때문이다.

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

같은 노드를 골라도 막지 않고 이렇게 알린다. 대조군이 없으면 cross-node 수치를 해석할 수 없기
때문이다.

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

`--cpunodebind` 이 **양쪽 모두 source 노드**인 것이 핵심이다. CPU 위치를 고정해야 두 프로세스의
차이가 **버퍼가 어느 노드에 있는가, 그 하나만** 남는다. 한쪽 CPU를 자기 노드로 주면 그 프로세스는
로컬 접근이 되어 재려던 것이 사라진다.

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

프로세스를 두 개 띄운다. rank는 **etcd 등록 순서**로 정해지므로
([`etcd_rt.cpp:77-81`](https://github.com/ai-dynamo/nixl/blob/main/benchmark/nixlbench/src/runtime/etcd/etcd_rt.cpp))
먼저 등록한 쪽이 rank 0 = initiator다. 그래서 두 번째 프로세스를 2초 늦게 띄운다. `numactl` 은
프로세스 단위 정책이므로, 서로 다른 `--membind` 를 주면 두 버퍼가 다른 노드에 놓인다.

etcd는 이미지에 포함되어 있어 pod 안에서 자동으로 뜬다. 이전 실행이 남긴 프로세스와 rank 키는
매 실행 전에 정리한다.

`UCX ERROR failed to get interface index for <nic>: No such device` 는 무시해도 되는 로그다.
pod 네임스페이스에 호스트 NIC이 없어서 나는 것이고, 같은 호스트 내 전송이라 NIC을 쓰지 않는다.

rank 0 로그만 실시간으로 흐르고 rank 1은 종료 후 출력된다. 둘을 같은 터미널에 동시에 쓰면
뒤섞여 읽을 수 없기 때문이다.

블록 크기를 바꿔도 대역폭이 평평하면 **어떤 상한에 도달한 것**이다. per-op 오버헤드 지배 구간이
아니라는 뜻이므로 대역폭 측정으로서는 좋은 신호다.

## B. memory → storage

### B-1. 대상 디렉터리

```
nixlbench treats --filepath as a DIRECTORY and creates
nixlbench_posix_test_file_* inside it, so the directory must exist.

target directory (default: /mnt/nixlbench-data/nixlbench, 그대로 쓰려면 엔터):
target: /mnt/nixlbench-data/nixlbench
```

기본값은 pod의 실제 마운트 경로에서 유도한다. 스크립트가 `mkdir -p` 를 먼저 한다.

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

단일 프로세스를 포그라운드로 실행하므로 출력이 바로 화면에 나온다.

---

결과가 나오면 [검증](#검증) 으로 넘어간다. 숫자를 믿기 전에 배치 검증과 대조군을 먼저 봐야 한다.

## 시나리오 파라미터

| 파라미터 | 기본값 | 대역폭에 미치는 영향 |
|---|---|---|
| block size sweep | 1 MiB ~ 16 MiB | **직접.** 전송 1건당 크기. 작으면 per-op 오버헤드가 지배한다 |
| batch size | 64 | **직접.** 한 번에 제출하는 descriptor 수 = 큐 깊이 |
| threads | 8 | **직접.** 병렬도 |
| buffer per process | 8 GiB | **직접 영향 없음.** 아래 제약을 만족할 만큼만 크면 된다 |
| iterations | 256 (+32 warmup) | 측정 시간·평균화. peak 값 자체엔 영향 없음 |

nixlbench가 강제하는 제약:

```
max_block_size × max_batch_size  ≤  total_buffer_size ÷ num_threads
```

`total_buffer_size` 는 독립 손잡이가 아니라 **나머지 세 개의 결과**다. 스크립트가 실행 전에 이
계산을 검사하고 어긋나면 필요한 값으로 올릴지 물어본다. nixlbench 자신은 etcd 랑데뷰까지 끝낸
뒤에야 거부하므로, 그때 실패하면 원인을 찾기 번거롭다.

버퍼가 작을 때의 진짜 위험은 대역폭 제한이 아니라 **working set이 L3에 들어가버리는 것**이다.
그러면 메모리 대역폭이 아니라 캐시 대역폭을 재게 되고, 원격 노드와 로컬이 비슷하게 빠르게 나와서
"차이 없음"으로 오판한다. GiB 규모를 유지하면 이 함정을 피한다.

## 플래그별 설명

| 플래그 | 의미 |
|---|---|
| `--membind=N` | **하드** 바인딩. 노드 N에만 할당하고 부족하면 다른 노드로 넘어가지 않고 OOM |
| `--preferred=N` | **소프트** 바인딩. 노드 N 우선, 부족하면 다른 노드 사용 |
| `--cpunodebind=N` | 스레드를 노드 N의 CPU에 제한. CPU 없는 노드를 주면 실행 불가 |
| `--initiator_seg_type DRAM` | initiator 버퍼를 호스트 메모리에 (VRAM 아님) → numactl 정책 대상 |
| `--target_seg_type DRAM` | target 버퍼도 호스트 메모리에. memory → memory 모드에 필요 |
| `--posix_api_type URING` | io_uring 경로. `AIO` / `POSIXAIO` 도 가능 |
| `--storage_enable_direct` | O_DIRECT. 페이지 캐시를 우회해 실제 디바이스를 측정 |
| `--posix_kernel_queue_size` | AIO/URING 커널 큐 깊이 (기본 256) |

## `--filepath` 는 디렉터리다

nixlbench는 `--filepath` 를 **디렉터리 프리픽스**로 쓰고 그 아래에
`nixlbench_posix_test_file_<name>_<i>` 를 만든다
([`nixl_worker.cpp:810-825`](https://github.com/ai-dynamo/nixl/blob/main/benchmark/nixlbench/src/worker/nixl/nixl_worker.cpp)).
디렉터리가 없으면 `open(O_CREAT)` 이 ENOENT로 실패한다 (스크립트가 `mkdir -p` 를 먼저 한다).
상원 README의 `--filepath /mnt/storage/testfile` 예시는 파일처럼 보이지만, 실제로는 그 이름의
디렉터리 아래에 파일이 만들어진다.

---

## 검증

**실행 중에** 다른 셸에서 버퍼 배치를 확인한다. 끝나면 볼 수 없다.

```bash
kubectl exec <pod> -- bash -c 'for p in $(pgrep nixlbench); do numastat -p $p | tail -5; done'
```

두 프로세스의 RSS가 source 노드와 target 노드로 **갈려 있어야** 한다. 한쪽으로 몰려 있으면
`numactl` 정책이 먹지 않은 것이고 그 수치는 버릴 것이다.

그리고 **대조군을 반드시 같이 돌린다.** 같은 시나리오로 두 번:

```
source = node X, target = node X      로컬 기준값
source = node X, target = node Y      cross-node
```

둘의 대역폭 차이가 없으면 측정이 성립하지 않은 것이다. RSS가 갈렸는데도 차이가 없다면 워크로드가
메모리 대역폭에 병목이 없는 것이니 `threads` 나 `block max` 를 올려 압력을 높인다.

## 정리

```bash
./scripts/deploy-nixlbench.sh --delete
```

pod을 지우면 안에서 돌던 프로세스도 같이 정리된다. 테스트 파일은 hostPath라 노드에 남으므로,
지우려면 pod 삭제 전에 `kubectl exec <pod> -- rm -rf <ssd_dir>` 을 먼저 실행한다.

## 주의사항

- `--membind` 은 하드 바인딩이라 대상 노드 용량이 부족하면 OOM으로 죽는다
- 버퍼를 키울 때는 pod `limits.memory` 도 같이 키운다. 프로세스 2개 × 버퍼가 한도에 계산된다
- `--use_hugepages` 는 쓰지 않는다. 대상 노드에 hugepage 예약이 없으면 실패한다
- 노드 메모리를 페이지 캐시나 다른 프로세스와 공유하므로 격리가 약하다. 경향 파악용이다
