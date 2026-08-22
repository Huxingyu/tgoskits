# StarryOS Task 1 periodic-latency A/B

Both arms run the same in-Guest ncnn/YOLO workload on StarryOS (priority 89) while a 300-sample, 10 ms RT-Thread periodic probe (priority 90) shares pCPU1. Only the AxVisor scheduler feature changes.

| Metric (median across runs) | RR | bounded FP-RR | Change |
|---|---:|---:|---:|
| P99 wake-up jitter | 39.737 ms | 1.662 ms | 23.913x / 95.82% lower |
| P99.9 wake-up jitter | 43.051 ms | 1.803 ms | 95.81% lower |
| Maximum wake-up jitter | 43.051 ms | 1.803 ms | 95.81% lower |
| Misses above 1 ms | 300/300 | 62/300 | 79.33% lower |

## Per-run evidence

| Arm | Run | Mean | P99 | P99.9 / max | >1 ms | YOLO inference | lower-priority services |
|---|---|---:|---:|---:|---:|---:|---:|
| RR | rr-01 | 23.465 ms | 37.587 ms | 39.997 ms / 39.997 ms | 300/300 | 22.237 s | n/a |
| RR | rr-02 | 23.437 ms | 39.737 ms | 43.051 ms / 43.051 ms | 300/300 | 22.266 s | n/a |
| RR | rr-03 | 26.466 ms | 40.007 ms | 50.987 ms / 50.987 ms | 300/300 | 19.788 s | n/a |
| FP-RR | fp-rr-01 | 0.894 ms | 1.327 ms | 1.545 ms / 1.545 ms | 40/300 | 22.276 s | 93 |
| FP-RR | fp-rr-02 | 0.980 ms | 1.732 ms | 2.835 ms / 2.835 ms | 62/300 | 23.005 s | 92 |
| FP-RR | fp-rr-03 | 1.051 ms | 1.662 ms | 1.803 ms / 1.803 ms | 133/300 | 22.872 s | 87 |

The P99 ratio is the supported near-10x claim. P99.9 and maximum are reported separately and must not be described as having the same improvement ratio.
