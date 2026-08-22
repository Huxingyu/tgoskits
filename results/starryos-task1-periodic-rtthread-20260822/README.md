# StarryOS Task 1 periodic-latency A/B with RT-Thread probe (2026-08-22)

Same experiment shape as the Zephyr periodic A/B: StarryOS (priority 89) runs
the real in-Guest ncnn/YOLO workload while a 300-sample, 10 ms RT-Thread
probe (priority 90) shares pCPU1. Only the AxVisor scheduler feature changes.

This is a **single-pair observation** (one RR run and one FP-RR run), not the
three-pair median used for the Zephyr evidence. The FP-RR arm's StarryOS
inference is very slow under the probing load (~90 s) and the QEMU harness
timeout (180 s) made repeated FP-RR runs unreliable, so the archived run is
the complete, verifier-passing pair.

## Results

| Metric | RR | bounded FP-RR | Change |
|---|---:|---:|---:|
| Mean wake-up jitter | 2827.8 ms | 0.235 ms | ~12000x lower |
| P99 wake-up jitter | 5533.2 ms | 2.230 ms | 2480x / 99.96% lower |
| P99.9 / maximum | 5598.3 ms | 5.633 ms | 99.90% lower |
| Samples later than 1 ms | 300/300 | 13/300 | 95.67% fewer |
| YOLO inference (same model) | 18.6 s | 89.8 s | slower under probe |
| FP-RR lower-priority services | n/a | 426 | exercised |

## Interpretation and caveats

- The improvement is real and much larger than the Zephyr probe's ~19x P99
  gain, but it measures RT-Thread's wake-up behavior under this hypervisor,
  not a direct comparison with Zephyr.
- RT-Thread's kernel tick is backed by the **emulated physical timer**
  (`CNTP_*`), which AxVisor delivers at host timer-wheel granularity
  (~10 ms). Under RR the tick IRQs are additionally delayed by the StarryOS
  YOLO workload, so RT-Thread wake-ups lag by seconds (mean 2.8 s). The
  FP-RR bounded service restores prompt delivery; the ~2 ms P99 is close to
  the emulated-timer floor.
- The FP-RR arm's 89.8 s inference is a real cost of this probing
  configuration: the high-priority probe plus bounded service delays the
  lower-priority StarryOS workload. In the probe-free Task 1 scheduler A/B,
  FP-RR inference was ~19-20 s. The periodic numbers therefore demonstrate
  the jitter trade-off, not a representative Task-3 inference cost.
- The `model-only` endpoint mode runs the YOLO inference without the T2N1
  network control loop so the probe experiment is not flooded by
  retransmissions to an absent peer. The 30 s inference deadline is skipped
  in this mode because the FP-RR probing arm legitimately exceeds it.

Reproduce with:

```bash
scripts/test/net-dual-guest/build-rtthread-periodic.sh
STARRY_TASK23_ROOTFS=tmp/axbuild/rootfs/rootfs-aarch64-alpine-modelonly.img/rootfs-aarch64-alpine-modelonly.img \
  ALLOW_DIRTY=1 STARRY_TASK1_PERIODIC_REPEATS=1 \
  bash scripts/test/net-dual-guest/run-starry-task1-periodic-rtthread-ab.sh \
  results/starryos-task1-periodic-rtthread-20260822
```
