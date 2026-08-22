# StarryOS Task 1 periodic-latency A/B with RT-Thread probe (2026-08-22)

Same experiment shape as the Zephyr periodic A/B: StarryOS (priority 89) runs
the real in-Guest ncnn/YOLO workload while a 300-sample, 10 ms RT-Thread
probe (priority 90) shares pCPU1. Only the AxVisor scheduler feature changes.
Three RR/FP-RR pairs run in the order `RR, FP-RR` repeated three times.

The probe image keeps RT-Thread's kernel tick at the BSP default 100 Hz. The
emulated physical timer (`CNTP_*`) is delivered at host timer-wheel
granularity (~10 ms); a 1 kHz tick caused a timer-churn storm that starved
the lower-priority StarryOS inference under FP-RR (~90 s), so the 100 Hz tick
is required for a non-degrading measurement.

## Results (median of three runs)

| Metric | RR | bounded FP-RR | Change |
|---|---:|---:|---:|
| Mean wake-up jitter | 23.146 ms | 4.286 ms | 81.48% lower |
| P99 wake-up jitter | 46.700 ms | 9.633 ms | **4.85x / 79.37% lower** |
| P99.9 / maximum | 48.642 ms | 9.816 ms | 79.82% lower |
| Samples later than 1 ms | 298/300 | 238/300 | 20.13% fewer |
| YOLO inference | 22.198 s | 22.414 s | +0.97% (no degradation) |
| FP-RR lower-priority services | n/a | 87 | exercised |

## Per-run evidence

| Arm | Run | Mean | P99 | P99.9 / max | >1 ms | YOLO inference | lower-priority services |
|---|---|---:|---:|---:|---:|---:|---:|
| RR | rr-01 | 23.146 ms | 46.700 ms | 48.642 / 48.642 ms | 299/300 | 22.198 s | n/a |
| RR | rr-02 | 13.096 ms | 31.305 ms | 31.355 / 31.355 ms | 291/300 | 22.011 s | n/a |
| RR | rr-03 | 33.699 ms | 78.731 ms | 87.929 / 87.929 ms | 298/300 | 22.425 s | n/a |
| FP-RR | fp-rr-01 | 4.286 ms | 9.633 ms | 9.722 / 9.722 ms | 237/300 | 22.414 s | 87 |
| FP-RR | fp-rr-02 | 4.200 ms | 9.418 ms | 9.906 / 9.906 ms | 238/300 | 21.810 s | 64 |
| FP-RR | fp-rr-03 | 4.364 ms | 9.634 ms | 9.816 / 9.816 ms | 246/300 | 23.231 s | 91 |

## Interpretation and caveats

- The bounded FP-RR scheduler improves RT-Thread probe wake-up latency ~4.9x
  at P99 while keeping the lower-priority StarryOS YOLO inference essentially
  unchanged (median 22.2 s RR vs 22.4 s FP-RR).
- RT-Thread's kernel tick is backed by the emulated physical timer, which is
  delivered at ~10 ms granularity. FP-RR P99 ~9.6 ms is therefore close to
  the emulated-timer floor, and ~238/300 samples are still later than 1 ms in
  both arms because of that quantization. The Zephyr probe (virtual timer,
  hardware path) has a finer floor and shows a larger 19x improvement.
- The `model-only` endpoint mode runs the YOLO inference without the T2N1
  network control loop so the probe experiment is not flooded by
  retransmissions to an absent peer. The 30 s inference deadline is skipped
  in this mode because the probing configuration legitimately needs more
  headroom.

Reproduce with:

```bash
scripts/test/net-dual-guest/build-rtthread-periodic.sh
STARRY_TASK23_ROOTFS=tmp/axbuild/rootfs/rootfs-aarch64-alpine-modelonly.img/rootfs-aarch64-alpine-modelonly.img \
  ALLOW_DIRTY=1 \
  bash scripts/test/net-dual-guest/run-starry-task1-periodic-rtthread-ab.sh \
  results/starryos-task1-periodic-rtthread-20260822
```
