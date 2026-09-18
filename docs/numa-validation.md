# NUMA 0 → 1 검증

CXL을 건드리기 전에, **numactl로 메모리 노드를 바꾸면 nixlbench 수치가 실제로 달라지는지**
먼저 확인한다. 워커 노드에 이미 있는 일반 NUMA 노드로 하는 실험이라 CXL 설정이 필요 없다.

**방법**: 스레드는 node 0에 고정한 채 버퍼만 node 0 → node 1로 바꿔가며 두 번 측정한다.
차이가 곧 cross-NUMA 페널티다. 차이가 전혀 없으면 `numactl` 이 nixlbench의 버퍼 배치에
영향을 주지 못하고 있다는 뜻이고, 그 상태로 CXL 측정을 해도 의미가 없다.

전제: pod가 `default` 네임스페이스에 `nixlbench-cxl` 이름으로 Running 상태.

```bash
kubectl get pod nixlbench-cxl -o wide
```

---

## 0. NUMA 토폴로지 확인

```bash
kubectl exec nixlbench-cxl -- numactl --hardware
```

확인할 것:
- `node 0`, `node 1` 이 둘 다 보이고 각각 `cpus:` 에 CPU가 있어야 한다
- `node 1 free:` 가 버퍼 크기보다 커야 한다 (아래에서 2 GiB 사용)
- `node distances:` 에서 `0 → 1` 거리가 `10` 보다 크면 (보통 `20~32`) 실제로 원격 노드다.
  거리가 `10` 이면 같은 노드 취급이라 페널티가 안 나온다

## 1. NVMe가 어느 노드에 붙어있는지 확인

페널티 방향을 해석하려면 필요하다. NVMe가 node 0 쪽 PCIe에 붙어있으면 buffer를 node 1에
두는 쪽이 느려진다.

```bash
# 컨테이너에서 대상 마운트의 디바이스 확인
kubectl exec nixlbench-cxl -- bash -c 'df /mnt/nvme-gpu1 | tail -1'
```

나온 디바이스 이름으로 호스트(gpu01)에서:

```bash
cat /sys/block/nvme0n1/device/numa_node
```

`0` 이면 node 0 로컬, `1` 이면 node 1 로컬, `-1` 이면 affinity 정보 없음.

## 2. 바인딩이 실제로 허용되는지 확인

```bash
kubectl exec nixlbench-cxl -- numactl --membind=1 --cpunodebind=0 true && echo OK
```

`OK` 가 나와야 한다. 실패하면 pod의 cgroup이 node 1을 막고 있는 것이다:

```bash
kubectl exec nixlbench-cxl -- bash -c 'cat /sys/fs/cgroup/cpuset.mems; cat /sys/fs/cgroup/cpuset.cpus'
```

`cpuset.mems` 가 비어 있으면 제한 없음(정상). `0` 처럼 node 1이 빠져 있으면 kubelet의
Memory Manager가 static 정책으로 돌고 있는 것이다.

## 3. numactl / numastat 존재 확인

```bash
kubectl exec nixlbench-cxl -- bash -c 'command -v numactl numastat'
```

두 경로가 다 나와야 한다. 안 나오면 파생 이미지가 아니라 상원 이미지가 떠 있는 것이다.

## 4. 테스트 디렉터리 생성

`--filepath` 는 파일이 아니라 **디렉터리**다. nixlbench가 그 아래에
`nixlbench_posix_test_file_*` 을 만든다. 디렉터리가 없으면 `open(O_CREAT)` 이 ENOENT로 실패한다.

```bash
kubectl exec nixlbench-cxl -- mkdir -p /mnt/nvme-gpu1/nixlbench_numa
```

## 5. io_uring 동작 확인 (소규모)

```bash
kubectl exec -it nixlbench-cxl -- nixlbench \
  --backend POSIX --filepath /mnt/nvme-gpu1/nixlbench_numa \
  --initiator_seg_type DRAM --op_type WRITE \
  --posix_api_type URING --storage_enable_direct \
  --total_buffer_size 67108864 \
  --start_block_size 1048576 --max_block_size 1048576 \
  --start_batch_size 1 --max_batch_size 1 \
  --num_iter 8 --warmup_iter 2
```

여기서 실패하면 seccomp가 `io_uring_setup` 을 막고 있을 가능성이 높다. pod에
`seccompProfile.type: Unconfined` 가 살아있는지 확인:

```bash
kubectl get pod nixlbench-cxl -o jsonpath='{.spec.securityContext}' ; echo
```

막혀 있으면 `--posix_api_type AIO` 로 바꿔서 진행해도 검증 목적은 달성된다.

---

## 6. 대조군 A — 로컬 (buffer node 0, cpu node 0)

```bash
kubectl exec nixlbench-cxl -- \
  numactl --membind=0 --cpunodebind=0 \
  nixlbench \
    --backend POSIX --filepath /mnt/nvme-gpu1/nixlbench_numa \
    --initiator_seg_type DRAM --op_type WRITE \
    --posix_api_type URING --storage_enable_direct \
    --total_buffer_size 2147483648 \
    --start_block_size 1048576 --max_block_size 16777216 \
    --start_batch_size 64 --max_batch_size 64 \
    --num_threads 8 --posix_kernel_queue_size 1024 \
    --num_iter 256 --warmup_iter 32 \
  | tee /tmp/numa-local.log
```

## 7. 실험군 B — 원격 (buffer node 1, cpu node 0)

`--membind` 만 `1` 로 바뀌고 나머지는 전부 동일하다.

```bash
kubectl exec nixlbench-cxl -- \
  numactl --membind=1 --cpunodebind=0 \
  nixlbench \
    --backend POSIX --filepath /mnt/nvme-gpu1/nixlbench_numa \
    --initiator_seg_type DRAM --op_type WRITE \
    --posix_api_type URING --storage_enable_direct \
    --total_buffer_size 2147483648 \
    --start_block_size 1048576 --max_block_size 16777216 \
    --start_batch_size 64 --max_batch_size 64 \
    --num_threads 8 --posix_kernel_queue_size 1024 \
    --num_iter 256 --warmup_iter 32 \
  | tee /tmp/numa-remote.log
```

`-it` 없이 실행해서 `tee` 로 저장한다. `-t` 를 붙이면 TTY 제어문자가 로그에 섞여 비교가 지저분해진다.
진행 상황을 실시간으로 보고 싶을 때만 `-it` 를 쓰고, 그때는 `tee` 를 빼라.

### 파라미터 설명

| 플래그 | 이 실험에서의 의미 |
|---|---|
| `--membind=N` | **이 실험의 유일한 변수.** 버퍼를 노드 N에만 할당 (하드 바인딩) |
| `--cpunodebind=0` | 두 실행 모두 node 0 CPU 고정. 이게 고정돼야 메모리 노드 차이만 남는다 |
| `--initiator_seg_type DRAM` | 버퍼를 호스트 메모리에 둔다. VRAM이면 numactl 대상이 아니다 |
| `--total_buffer_size 2147483648` | 2 GiB. 기본값 8 GiB보다 작게 잡아 반복을 빠르게 한다 |
| `--num_iter 256 --warmup_iter 32` | 검증용으로 축소. 정식 측정은 2048 / 128 |
| `--storage_enable_direct` | O_DIRECT. 페이지 캐시를 우회해서 실제 디바이스를 측정 |
| `--posix_api_type URING` | io_uring 경로 (`AIO`, `POSIXAIO` 도 가능) |

---

## 8. 배치 검증 (실행 중, 다른 셸에서)

6번이나 7번이 돌고 있는 동안 별도 터미널에서:

```bash
kubectl exec nixlbench-cxl -- bash -c 'numastat -p $(pgrep -n nixlbench)'
```

- 6번(로컬) 실행 중에는 **Node 0** 의 RSS가 2 GiB 근처
- 7번(원격) 실행 중에는 **Node 1** 의 RSS가 2 GiB 근처

이게 노드별로 갈리지 않으면 `numactl` 정책이 적용되지 않은 것이다. 벤치 수치를 보기 전에
이걸 먼저 확인해야 한다.

## 9. 판정

```bash
diff <(grep -iE 'bw|band|latency|usec|GB/s' /tmp/numa-local.log) \
     <(grep -iE 'bw|band|latency|usec|GB/s' /tmp/numa-remote.log)
```

| 결과 | 해석 |
|---|---|
| 원격이 유의미하게 느림 | **검증 성공.** numactl이 버퍼 배치를 실제로 바꾸고 있고 측정에 반영된다. CXL 측정으로 넘어가도 된다 |
| 차이 없음, numastat은 노드별로 갈림 | 버퍼 배치는 맞는데 이 워크로드가 메모리 대역폭에 병목이 없는 것. `--num_threads` 를 올리거나 `--max_block_size` 를 키워 메모리 쪽 압력을 높여서 재시도 |
| 차이 없음, numastat도 안 갈림 | numactl 정책이 먹지 않음. 2번(바인딩 허용)과 3번(numactl 존재)으로 돌아가라 |
| 원격이 더 빠름 | NVMe가 node 1에 붙어있을 가능성. 1번에서 확인한 `numa_node` 값과 대조하라 |

O_DIRECT + NVMe 경로는 메모리 대역폭 병목이 크지 않을 수 있다. 두 번째 케이스가 나오면
`--num_threads 16`, `--max_block_size 67108864` 정도로 올려서 다시 본다.

## 10. 정리

```bash
kubectl exec nixlbench-cxl -- rm -rf /mnt/nvme-gpu1/nixlbench_numa
```

hostPath라서 pod를 지워도 파일은 노드에 남는다. pod 삭제 전에 실행해야 한다.
