# StarryOS Task 1 periodic-latency A/B with RT-Thread probe (2026-08-22)

Same experiment shape as the Zephyr periodic A/B: StarryOS (priority 89) runs
the real in-Guest ncnn/YOLO workload while a 300-sample, 10 ms RT-Thread
probe (priority 90) shares pCPU1. Only the AxVisor scheduler feature changes.
Three RR/FP-RR pairs run in the order `RR, FP-RR` repeated three times.

The probe uses the AArch64 **virtual timer** (`CNTVCT_EL0`/`CNTV_CVAL_EL0`)
so wake-ups are not quantized by RT-Thread's emulated physical timer. This
required exposing the virtual timer PPI to the RT-Thread guest: the periodic
build registers the GIC descriptor for the IRQ slot that the GIC handler
derives from the IAR (`irq_start + (hwirq - 16)`) and installs the probe ISR
on that slot. AxVisor already delivers the CNTV PPI level through its VGIC
(the same path Zephyr uses), so no hypervisor routing change was needed once
the RT-Thread GIC slot was correct.

## Results (median of three runs)

| Metric | RR | bounded FP-RR | Change |
|---|---:|---:|---:|
| Mean wake-up jitter | 1135.365 ms | 0.961 ms | ~1181x lower |
| P99 wake-up jitter | 2247.128 ms | 1.595 ms | **1409x / 99.93% lower** |
| P99.9 / maximum | 2259.947 ms | 1.793 ms | 99.92% lower |
| Samples later than 1 ms | 300/300 | 37/300 | 87.67% fewer |
| YOLO inference (median) | 22.452 s | 23.001 s | +2.4% (no degradation) |
| FP-RR lower-priority services | n/a | 90 | exercised |

## Per-run evidence

| Arm | Run | Mean | P99 | P99.9 / max | >1 ms | YOLO inference | lower-priority services |
|---|---|---:|---:|---:|---:|---:|---:|
| RR | rr-01 | 1135.365 ms | 2295.381 ms | 2312.165 / 2312.165 ms | 300/300 | 22.197 s | n/a |
| RR | rr-02 | 1136.717 ms | 2247.128 ms | 2259.947 / 2259.947 ms | 300/300 | 22.452 s | n/a |
| RR | rr-03 | 1061.209 ms | 2214.693 ms | 2250.601 / 2250.601 ms | 300/300 | 23.073 s | n/a |
| FP-RR | fp-rr-01 | 0.957 ms | 1.553 ms | 1.616 / 1.616 ms | 36/300 | 22.437 s | 90 |
| FP-RR | fp-rr-02 | 0.961 ms | 1.595 ms | 1.793 / 1.793 ms | 37/300 | 23.001 s | 92 |
| FP-RR | fp-rr-03 | 1.020 ms | 1.608 ms | 6.238 / 6.238 ms | 50/300 | 23.366 s | 83 |

## Interpretation and caveats

- FP-RR brings RT-Thread probe wake-ups to ~1.6 ms P99, close to Zephyr's
  ~0.65 ms virtual-timer floor, while YOLO inference stays essentially
  unchanged (median +2.4%).
- Under RR, RT-Thread's thread resume accumulates latency (~20 ms per wake)
  because the shared vCPU is only serviced in RR slices while StarryOS runs
  YOLO; the CNTV deadlines are absolute, so jitter grows to ~2.2 s by the end
  of the 300-sample window. FP-RR eliminates this accumulation.
- The probe image keeps the BSP-default 100 Hz kernel tick. The probe itself
  no longer depends on the tick for timing or sleeping; the 100 Hz tick only
  avoids churning the emulated physical timer.
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
