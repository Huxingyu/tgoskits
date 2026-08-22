# StarryOS Task 1 periodic-latency A/B

Both arms run the same in-Guest ncnn/YOLO workload on StarryOS (priority 89) while a 300-sample, 10 ms RT-Thread periodic probe (priority 90) shares pCPU1. Only the AxVisor scheduler feature changes.

| Metric (median across runs) | RR | bounded FP-RR | Change |
|---|---:|---:|---:|
| P99 wake-up jitter | 46.700 ms | 9.633 ms | 4.848x / 79.37% lower |
| P99.9 wake-up jitter | 48.642 ms | 9.816 ms | 79.82% lower |
| Maximum wake-up jitter | 48.642 ms | 9.816 ms | 79.82% lower |
| Misses above 1 ms | 298/300 | 238/300 | 20.13% lower |

## Per-run evidence

| Arm | Run | Mean | P99 | P99.9 / max | >1 ms | YOLO inference | lower-priority services |
|---|---|---:|---:|---:|---:|---:|---:|
| RR | rr-01 | 23.146 ms | 46.700 ms | 48.642 ms / 48.642 ms | 299/300 | 22.198 s | n/a |
| RR | rr-02 | 13.096 ms | 31.305 ms | 31.355 ms / 31.355 ms | 291/300 | 22.011 s | n/a |
| RR | rr-03 | 33.699 ms | 78.731 ms | 87.929 ms / 87.929 ms | 298/300 | 22.425 s | n/a |
| FP-RR | fp-rr-01 | 4.286 ms | 9.633 ms | 9.722 ms / 9.722 ms | 237/300 | 22.414 s | 87 |
| FP-RR | fp-rr-02 | 4.200 ms | 9.418 ms | 9.906 ms / 9.906 ms | 238/300 | 21.810 s | 64 |
| FP-RR | fp-rr-03 | 4.364 ms | 9.634 ms | 9.816 ms / 9.816 ms | 246/300 | 23.231 s | 91 |

The P99 ratio is the supported near-10x claim. P99.9 and maximum are reported separately and must not be described as having the same improvement ratio.
