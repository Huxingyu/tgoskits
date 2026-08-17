# Active-burner scheduler A/B

Date: 2026-08-16

This is the software scheduler comparison with the same background load
already running before either guest starts:

- RR board: `board-qemu-aarch64-rr.toml`
- fixed board: `board-qemu-aarch64-rt.toml`
- scenario: `stress-noiso`
- burner: `pCPU1`, `10 ms busy / 53 ms sleep`, no delayed start
- Zephyr: `pCPU1`, 300 periodic samples, 1 ms tolerance
- Linux: 2 vCPUs on `pCPU2/pCPU3`, 90-second cyclictest window and stress-ng

The independent variable is the AxVisor host scheduler (`sched-rr` versus
`sched-rt`, fixed-priority FIFO). Guest images, VM topology, affinity, and
offered load are unchanged. The burner emits `RT_BURNER_READY` before VM
launch in both cases.

## Zephyr latency

| Metric | RR | Fixed priority | Reduction | Ratio |
|---|---:|---:|---:|---:|
| P99 | 10.434 ms | 0.810 ms | 92.24% | 12.89x |
| P99.9 | 10.707 ms | 0.847 ms | 92.09% | 12.65x |
| Maximum | 10.707 ms | 0.969 ms | 90.95% | 11.05x |
| Misses above 1 ms | 53/300 | 0/300 | 100% | 53 -> 0 |

RR values are in `rr/stress-noiso/zephyr-stats.txt`. Fixed values were
recomputed from the 300 raw rows in `fixed-priority/stress-noiso/run.log`;
the runner did not emit a summary because the Linux stability gate failed.

## Stability gate

The fixed-priority run did **not** pass the full acceptance gate. Linux stopped
emitting progress after `uptime_s=100.55`; the post-stall capture reports an
RCU-preempt kthread starvation of 5,268 jiffies. Therefore these latency
numbers demonstrate the scheduling-path effect, but are not yet a formal
end-to-end pass for Task 1. The next change must preserve the low tail latency
while guaranteeing bounded service for guest housekeeping and completion of
the 90-second Linux workload.
