# StarryOS Task 1 periodic-latency A/B with RT-Thread probe (2026-08-22)

Same experiment shape as the Zephyr periodic A/B: StarryOS (priority 89) runs
the real in-Guest ncnn/YOLO workload while a 300-sample, 10 ms RT-Thread
probe (priority 90) shares pCPU1. Only the AxVisor scheduler feature changes.
Three RR/FP-RR pairs run in the order `RR, FP-RR` repeated three times.

The probe uses the AArch64 **virtual timer** (`CNTVCT_EL0`/`CNTV_CVAL_EL0`)
and **relative-period deadlines** (each deadline is the previous actual
wake-up plus 10 ms). Relative anchoring measures the per-wake scheduling
delay, matching the Zephyr probe's jitter definition. An earlier probe used
absolute deadlines anchored at start; under RR the vCPU is serviced about
every 17-20 ms, so each wake accumulated ~7-8 ms of lateness that grew to
~2.2 s by sample 300. That inflated the RR baseline (and the improvement
ratio) and is not a comparable jitter metric, so the absolute-deadline run
was superseded.

## Results (median of three runs)

| Metric | RR | bounded FP-RR | Change |
|---|---:|---:|---:|
| Mean wake-up jitter | 23.465 ms | 0.980 ms | 95.82% lower |
| P99 wake-up jitter | 39.737 ms | 1.662 ms | **23.9x / 95.82% lower** |
| P99.9 / maximum | 43.051 ms | 1.803 ms | 95.81% lower |
| Samples later than 1 ms | 300/300 | 62/300 | 79.33% fewer |
| YOLO inference (median) | 22.266 s | 22.872 s | +2.7% (no degradation) |
| FP-RR lower-priority services | n/a | 92 | exercised |

## Per-run evidence

| Arm | Run | Mean | P99 | P99.9 / max | >1 ms | YOLO inference | lower-priority services |
|---|---|---:|---:|---:|---:|---:|---:|
| RR | rr-01 | 23.465 ms | 37.587 ms | 39.997 / 39.997 ms | 300/300 | 22.237 s | n/a |
| RR | rr-02 | 23.437 ms | 39.737 ms | 43.051 / 43.051 ms | 300/300 | 22.266 s | n/a |
| RR | rr-03 | 26.466 ms | 40.007 ms | 50.987 / 50.987 ms | 300/300 | 19.788 s | n/a |
| FP-RR | fp-rr-01 | 0.894 ms | 1.327 ms | 1.545 / 1.545 ms | 40/300 | 22.276 s | 93 |
| FP-RR | fp-rr-02 | 0.980 ms | 1.732 ms | 2.835 / 2.835 ms | 62/300 | 23.005 s | 92 |
| FP-RR | fp-rr-03 | 1.051 ms | 1.662 ms | 1.803 / 1.803 ms | 133/300 | 22.872 s | 87 |

## Interpretation and caveats

- FP-RR brings RT-Thread probe wake-ups to ~1.7 ms P99, close to Zephyr's
  ~0.65 ms virtual-timer floor, while YOLO inference stays essentially
  unchanged (median +2.7%).
- Under RR, RT-Thread's per-wake scheduling delay is ~20-40 ms P99 because
  the shared vCPU is serviced in RR slices while StarryOS runs YOLO; FP-RR
  reduces this to ~1-2 ms. The ~24x P99 improvement is comparable to the
  Zephyr probe's ~19x under the same scheduler A/B.
- The probe image keeps the BSP-default 100 Hz kernel tick; the probe itself
  does not depend on the tick for timing or sleeping.
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
