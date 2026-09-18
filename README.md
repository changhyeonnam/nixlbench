# nixlbench on CXL memory (Kubernetes)

CXL 메모리를 [nixlbench](https://github.com/ai-dynamo/nixl/tree/main/benchmark/nixlbench)의
DRAM 버퍼로 사용해서 NVMe 스토리지 성능을 측정하는 절차와 스크립트.

컨테이너 이미지를 K8s `default` 네임스페이스에 대기형 pod로 띄우고, `kubectl exec` 으로
벤치마크를 하나씩 실행하는 방식이다.

## 목차

1. [환경](#환경)
2. [원리 — 왜 코드 수정 없이 되는가](#원리--왜-코드-수정-없이-되는가)
3. [이미지 — 왜 파생 이미지가 필요한가](#이미지--왜-파생-이미지가-필요한가)
4. [1단계: 이미지 빌드 & push](#1단계-이미지-빌드--push)
5. [2단계: Pod 배포](#2단계-pod-배포)
6. [3단계: Preflight 검증](#3단계-preflight-검증)
7. [4단계: 벤치마크 실행 (방법 A)](#4단계-벤치마크-실행-방법-a)
8. [5단계: 배치 검증](#5단계-배치-검증)
9. [주의사항](#주의사항)
10. [트러블슈팅](#트러블슈팅)
11. [정리](#정리)

---

## 환경

| 항목 | 값 |
|---|---|
| 클러스터 | mgmt01 (control-plane) + gpu01 (GPU worker) |
| 네임스페이스 | `default` |
| 이미지 | `changhyeonnam/nixlbench:latest` (Docker Hub, public) |
| 대상 노드 | `gpu01` (CXL 메모리 + NVMe 보유 노드) |
| CXL NUMA 노드 | **2 (가정)** — preflight에서 실측 검증 |
| 스토리지 | `/mnt/nvme-gpu1` (hostPath) |
| 아키텍처 | x86_64 |

### 호스트 사전 조건

CXL 영역이 `devdax` 가 아니라 **`system-ram` 으로 전환**되어 있어야 한다. 전환되면
CPU 없는 메모리 전용 NUMA 노드가 생긴다.

```bash
# 호스트(gpu01)에서
daxctl list -u
numactl --hardware      # CPU 없는 추가 노드가 보여야 함
```

### RBAC

이 pod는 **K8s API를 호출하지 않는다.** POSIX 단일 인스턴스 벤치마크는 etcd 조정도,
Dynamo 서비스 디스커버리도 쓰지 않는다. 따라서 별도 ServiceAccount / Role / RoleBinding
이 필요 없고, Dynamo DGD에서 요구하는 `POD_UID` / `POD_NAME` / `POD_NAMESPACE` env도
필요 없다.

---

## 원리 — 왜 코드 수정 없이 되는가

nixlbench는 DRAM 버퍼를 다음과 같이 할당한다
([`nixl_worker.cpp:504,511`](https://github.com/ai-dynamo/nixl/blob/main/benchmark/nixlbench/src/worker/nixl/nixl_worker.cpp)):

```c
int rc = posix_memalign(&addr, xferBenchConfig::page_size, size);
...
memset(addr, 0, size);
```

핵심은 **`memset` 이 할당 직후 같은 프로세스에서 실행된다**는 점이다. Linux는 물리 페이지를
first-touch 시점에 배치하므로, 프로세스의 메모리 정책을 CXL 노드로 고정해두면 그 `memset`
이 페이지를 CXL에 꽂는다. 따라서 `numactl` 로 정책만 씌우면 되고 nixlbench 코드는 손댈 필요가 없다.

같은 이유로 `numastat -p <pid>` 로 배치를 실측 검증할 수 있다 — 버퍼가 lazy allocation
상태로 남아있지 않기 때문이다.

---

## 이미지 — 왜 파생 이미지가 필요한가

nixl 상원 이미지(`benchmark/nixlbench/contrib/Dockerfile`)는 `libnuma-dev` 만 설치한다.
우분투에서 이 둘은 **다른 패키지**다:

| 패키지 | 제공하는 것 | 용도 |
|---|---|---|
| `libnuma-dev` (상원 이미지에 있음) | `/usr/include/numa.h`, `libnuma.so` | C 프로그램 **컴파일**용 헤더·라이브러리 |
| `numactl` (상원 이미지에 **없음**) | `/usr/bin/numactl`, `/usr/bin/numastat` | 터미널에서 **치는 명령어** |

방법 A는 전적으로 `numactl` 명령어에 의존하고, 검증은 `numastat` 에 의존한다. 상원 이미지
그대로는 `command not found` 로 끝난다.

그래서 `docker/Dockerfile` 이 상원 이미지 위에 `numactl` 패키지 한 장만 얹는다. 추가 레이어는
수 MB라서 빌드·push가 1분 내로 끝나고, 수십 GB짜리 하위 레이어는 재전송되지 않는다.

> 상원 `contrib/Dockerfile` 에 `numactl` 을 추가하는 것은 별도 PR 후보로 볼 만하다.
> NUMA 바인딩 벤치는 일반적인 사용 시나리오이고, `libnuma-dev` 만 있는 것은 누락에 가깝다.

---

## 1단계: 이미지 빌드 & push

```bash
cd ~/nixlbench

# 빌드 + 검증만 (push 없이)
PUSH=0 ./scripts/build-push.sh

# 빌드 + 검증 + push
./scripts/build-push.sh
```

기본값:

| 변수 | 기본값 | 설명 |
|---|---|---|
| `BASE_IMAGE` | `nixlbench:v1.3.1.dev.d2495941` | nixl `contrib/build.sh` 가 만든 로컬 원본 태그 |
| `TARGET_IMAGE` | `changhyeonnam/nixlbench:latest` | 빌드·push 대상 |
| `PUSH` | `1` | `0` 이면 push 생략 |

`BASE_IMAGE` 를 `TARGET_IMAGE` 와 같게 두면 자기 위에 자기를 쌓게 되어 실행할 때마다
numactl 레이어가 중첩된다. 그래서 base는 불변 로컬 태그로 고정해뒀다.

스크립트는 push 전에 두 가지를 검증하고, 실패하면 push하지 않는다:

1. `numactl` / `numastat` 바이너리 존재
2. `nixlbench` 의 미해결 동적 라이브러리 없음

> `libcuda.so.1 => not found` 는 검증에서 **의도적으로 제외**한다. 이 라이브러리는 이미지에
> 들어있는 게 아니라 nvidia-container-toolkit이 런타임에 주입하므로, GPU 없는 노드(mgmt01)에서
> 이미지를 검사하면 항상 not found로 나온다. 정상이다.

### 확인

```bash
docker run --rm changhyeonnam/nixlbench:latest numactl --hardware
docker manifest inspect changhyeonnam/nixlbench:latest | head -30
```

첫 명령에서 NUMA 노드 목록이 나오면 성공이다. 앞에 붙는 CUDA 배너와
`WARNING: The NVIDIA Driver was not detected` 는 GPU 없는 호스트에서 정상 출력이다.

---

## 2단계: Pod 배포

```bash
./scripts/deploy-pod.sh
```

매니페스트를 직접 적용해도 된다:

```bash
kubectl apply -f k8s/nixlbench-pod.yaml
kubectl wait --for=condition=Ready pod/nixlbench-cxl -n default --timeout=900s
kubectl get pod nixlbench-cxl -o wide
```

오버라이드:

```bash
NODE=gpu02 HOST_PATH=/mnt/nvme2 ./scripts/deploy-pod.sh
```

### 매니페스트에서 중요한 설정과 이유

| 설정 | 이유 |
|---|---|
| `command: ["sleep","infinity"]` + `restartPolicy: Never` | 대기형 워크벤치. exec으로 반복 실험하고 실행 사이에 환경을 들여다볼 수 있다 |
| `nodeSelector: kubernetes.io/hostname: gpu01` | CXL 메모리와 NVMe가 있는 노드에 고정 |
| `seccompProfile.type: Unconfined` | **io_uring 필수.** `RuntimeDefault` 프로파일은 `io_uring_setup` 을 차단해서 `--posix_api_type URING` 이 실패한다 |
| `hostPath: /mnt/nvme-gpu1` | 실제 NVMe를 때리기 위함. emptyDir이면 컨테이너 overlayfs를 측정해 수치가 무의미해진다 |
| `limits.memory: 64Gi` | CXL 페이지도 cgroup 메모리 한도에 계산된다. `--total_buffer_size` 보다 넉넉해야 실행 중 OOMKilled를 피한다 |
| `requests ≠ limits` (Burstable) | Guaranteed QoS가 되면 static CPU manager 정책이 배타적 cpuset을 할당할 수 있고, 그러면 `--cpunodebind` 이 바인딩할 CPU를 못 찾는다 |
| GPU 미요청 | POSIX + `--initiator_seg_type DRAM` 경로는 `cudaSetDevice` 를 호출하지 않는다. 공용 클러스터에서 B200을 점유하지 않기 위해 요청하지 않는다 (매니페스트에 주석으로 준비됨) |
| `privileged` 미사용 | `set_mempolicy`(numactl), O_DIRECT, `/sys/devices/system/node` 읽기 모두 특권이 필요 없다 |
| `imagePullPolicy: Always` | `latest` 태그를 덮어쓰며 반복하므로 stale 캐시 방지. 변경된 작은 레이어만 전송된다 |

---

## 3단계: Preflight 검증

**벤치 수치를 믿기 전에 반드시 통과시킬 단계.**

```bash
# [1] numactl / numastat 존재 — 둘 다 나와야 함. 안 나오면 상원 이미지가 떠 있는 것
kubectl exec nixlbench-cxl -- bash -c 'command -v numactl numastat'

# [2] NUMA 토폴로지 — node 2가 보이고 'cpus:' 가 비어야 함 (CPU 없는 메모리 전용 노드)
kubectl exec nixlbench-cxl -- numactl --hardware

# [3] 바인딩 허용 여부 — OK가 나와야 함
kubectl exec nixlbench-cxl -- numactl --membind=2 --cpunodebind=0 true && echo OK

# [3-a] 실패했을 때 원인 확인 — cpuset.mems가 비어 있으면 제한 없음(정상)
kubectl exec nixlbench-cxl -- bash -c 'cat /sys/fs/cgroup/cpuset.mems; cat /sys/fs/cgroup/cpuset.cpus'

# [4] 마운트 & O_DIRECT
kubectl exec nixlbench-cxl -- bash -c 'df -hT /mnt/nvme-gpu1'
kubectl exec nixlbench-cxl -- dd if=/dev/zero of=/mnt/nvme-gpu1/.odirect_test \
  bs=1M count=16 oflag=direct
kubectl exec nixlbench-cxl -- rm -f /mnt/nvme-gpu1/.odirect_test

# [5] io_uring 소규모 실행 (seccomp 차단 여부)
kubectl exec nixlbench-cxl -- mkdir -p /mnt/nvme-gpu1/nixlbench_preflight
kubectl exec -it nixlbench-cxl -- nixlbench \
  --backend POSIX --filepath /mnt/nvme-gpu1/nixlbench_preflight \
  --initiator_seg_type DRAM --op_type WRITE \
  --posix_api_type URING --storage_enable_direct \
  --total_buffer_size 67108864 \
  --start_block_size 1048576 --max_block_size 1048576 \
  --start_batch_size 1 --max_batch_size 1 \
  --num_iter 8 --warmup_iter 2
```

[2]에서 `node 2` 가 안 보이거나 CPU를 갖고 있으면 **가정이 틀린 것**이다. 출력된 토폴로지에서
실제 CXL 노드 번호를 찾아 이후 명령의 `--membind` 값을 교체하라.

### NUMA 0 → 1 사전 검증 (권장)

CXL 측정으로 넘어가기 전에, **numactl이 실제로 수치에 반영되는지** 일반 NUMA 노드로 먼저
확인하는 것이 좋다. CPU는 node 0에 고정한 채 버퍼만 node 0 / node 1로 바꿔 두 번 측정한다.

→ [`docs/numa-validation.md`](docs/numa-validation.md)

---

## 4단계: 벤치마크 실행 (방법 A)

```bash
# 테스트 디렉터리 (--filepath는 디렉터리다, 아래 참고)
kubectl exec nixlbench-cxl -- mkdir -p /mnt/nvme-gpu1/nixlbench_cxl

kubectl exec nixlbench-cxl -- \
  numactl --membind=2 --cpunodebind=0 \
  nixlbench \
    --backend POSIX --filepath /mnt/nvme-gpu1/nixlbench_cxl \
    --initiator_seg_type DRAM --op_type WRITE \
    --posix_api_type URING --storage_enable_direct \
    --total_buffer_size 8589934592 \
    --start_block_size 1048576 --max_block_size 16777216 \
    --start_batch_size 64 --max_batch_size 64 \
    --num_threads 8 --posix_kernel_queue_size 1024 \
    --num_iter 2048 --warmup_iter 128 \
  | tee /tmp/nixlbench-cxl.log
```

`-it` 없이 실행해서 `tee` 로 저장한다. `-t` 를 붙이면 TTY 제어문자가 로그에 섞인다.
진행 상황을 실시간으로 보려면 `-it` 를 쓰고 `tee` 를 빼라.

노드 여유가 애매하면 `--membind=2` 대신 `--preferred=2` 로 시작한다. 하드 바인딩이 아니라
부족할 때 다른 노드로 넘어가므로 OOM을 피할 수 있다.

### `--filepath` 는 디렉터리다

nixlbench는 `--filepath` 를 **디렉터리 프리픽스**로 쓰고 그 아래에
`nixlbench_posix_test_file_<name>_<i>` 를 만든다
([`nixl_worker.cpp:810-825`](https://github.com/ai-dynamo/nixl/blob/main/benchmark/nixlbench/src/worker/nixl/nixl_worker.cpp)).
디렉터리가 없으면 `open(O_CREAT)` 이 ENOENT로 실패하므로 `mkdir -p` 를 먼저 실행해야 한다.
상원 nixlbench README의 `--filepath /mnt/storage/testfile` 예시는 파일처럼 보이지만,
실제로는 그 이름의 디렉터리 아래에 파일이 만들어진다.

### 플래그별 설명

| 플래그 | 의미 |
|---|---|
| `--membind=N` | **하드** 바인딩. 노드 N에만 할당하고, 부족하면 다른 노드로 넘어가지 않고 OOM |
| `--preferred=N` | **소프트** 바인딩. 노드 N을 우선하되 부족하면 다른 노드 사용. 여유가 애매할 때 여기서 시작 |
| `--cpunodebind=N` | 스레드를 노드 N의 CPU에 제한 |
| `--initiator_seg_type DRAM` | 버퍼를 호스트 메모리에 (VRAM 아님) → numactl 정책 대상이 된다 |
| `--posix_api_type URING` | io_uring 경로. `AIO` / `POSIXAIO` 도 선택 가능 |
| `--storage_enable_direct` | O_DIRECT. 페이지 캐시를 우회해서 실제 디바이스를 측정 |
| `--posix_kernel_queue_size` | AIO/URING 커널 큐 깊이 (기본 256) |

---

## 5단계: 배치 검증

벤치 실행 중에 **다른 셸에서**:

```bash
kubectl exec nixlbench-cxl -- bash -c 'numastat -p $(pgrep -n nixlbench)'
```

해당 노드의 RSS가 `--total_buffer_size` 에 가깝게 잡혀 있어야 정상이다. 그렇지 않으면
메모리 정책이 적용되지 않은 것이다.

### 대조군 — 가장 중요한 검증

4단계 명령에서 `--membind` 만 바꿔 두 번 실행하고 비교한다.

```bash
# 로컬 DRAM 대조군: --membind=0
# CXL:            --membind=2
diff <(grep -iE 'bw|band|latency|usec|GB/s' /tmp/nixlbench-local.log) \
     <(grep -iE 'bw|band|latency|usec|GB/s' /tmp/nixlbench-cxl.log)
```

`numastat` RSS는 "버퍼가 거기 있다"까지만 증명한다. 두 실행의 대역폭·레이턴시 차이가
전혀 없으면 측정 경로를 다시 봐야 한다. 판정 기준은
[`docs/numa-validation.md`](docs/numa-validation.md) 9절 표와 같다.

---

## 주의사항

- **`--membind` 은 하드 바인딩이다.** 노드 용량이 부족하면 OOM으로 죽는다. 여유가 애매하면
  `--preferred=N` 으로 시작해 실제 배치를 확인하고 나서 `--membind` 로 넘어가라.
- **`--cpunodebind` 에 CXL 노드를 주면 안 된다.** CPU가 없어서 스레드가 스케줄될 곳이 없다.
  스크립트가 막아두었다.
- **`--use_hugepages` 를 쓰지 마라.** 이 플래그는 `MAP_HUGETLB` 경로를 타고, CXL 노드에
  hugepage가 예약돼 있지 않으면 실패한다.
- **격리가 약하다.** 커널이 그 노드 메모리를 페이지 캐시나 다른 프로세스에도 쓸 수 있다.
  경향 파악에는 충분하지만, 재현성 있는 정식 측정에는 방법 B/C가 낫다.
- **pod 메모리 한도.** CXL 페이지도 cgroup 한도에 계산된다. `--total_buffer_size` 를 키울 때는
  매니페스트의 `limits.memory` 도 같이 올려야 OOMKilled를 피한다.

## 방법 B / C

정식 측정용 대안. *(내용 미작성 — 채워 넣을 것)*

---

## 트러블슈팅

| 증상 | 원인 | 해결 |
|---|---|---|
| `numactl: command not found` | 상원 이미지를 그대로 쓰고 있음 | `./scripts/build-push.sh` 로 파생 이미지 빌드 후 pod 재배포 |
| `libnuma: Warning: Cannot parse node` / `Could not bind to node` | `cpuset.mems` 에 해당 노드가 없음 (kubelet Memory Manager static) | preflight [3] 확인. kubelet `--memory-manager-policy` 를 확인하거나 노드 정책 조정 |
| URING 실행 실패 | seccomp이 `io_uring_setup` 차단 | `seccompProfile.type: Unconfined` 가 admission에서 살아남았는지 확인 (`kubectl get pod -o yaml`). 네임스페이스에 Pod Security Admission `baseline`/`restricted` 라벨이 있으면 Unconfined가 거부된다 |
| `open ... No such file or directory` | `--filepath` 디렉터리가 없음 | `kubectl exec <pod> -- mkdir -p <dir>` |
| O_DIRECT 실패 | 백킹 파일시스템이 O_DIRECT 미지원 (tmpfs, 일부 네트워크 FS) | hostPath가 실제 NVMe의 ext4/xfs를 가리키는지 확인 |
| 실행 중 pod `OOMKilled` | `limits.memory` < 버퍼 + 오버헤드, 또는 CXL 노드 용량 부족 | 한도 상향, 또는 `--total_buffer_size` 축소, 또는 `--preferred=N` |
| pod `Pending` | `nodeSelector` 노드 없음, 또는 hostPath 디렉터리 부재 | `kubectl describe pod nixlbench-cxl` 로 이벤트 확인 |
| `ImagePullBackOff` | Hub에 push되지 않았거나 노드 디스크 부족 | `docker manifest inspect` 로 확인. 이미지가 수십 GB이므로 노드에 여유 공간 필요 |
| `libcuda.so.1 => not found` | 정상 | 드라이버가 런타임에 주입하는 라이브러리. GPU 없는 호스트에서는 항상 그렇게 보인다 |

---

## 정리

```bash
./scripts/deploy-pod.sh --delete
```

테스트 파일도 지우려면:

```bash
kubectl exec nixlbench-cxl -- rm -rf /mnt/nvme-gpu1/nixlbench_cxl
```

(pod 삭제 전에 실행해야 한다. hostPath라서 pod를 지워도 파일은 노드에 남는다.)
