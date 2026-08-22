# StarryOS Task 1 periodic-latency A/B

Both arms run the same in-Guest ncnn/YOLO workload on StarryOS (priority 89) while a 300-sample, 10 ms RT-Thread periodic probe (priority 90) shares pCPU1. Only the AxVisor scheduler feature changes.

| Metric (median across runs) | RR | bounded FP-RR | Change |
|---|---:|---:|---:|
| P99 wake-up jitter | 2247.128 ms | 1.595 ms | 1409.275x / 99.93% lower |
| P99.9 wake-up jitter | 2259.947 ms | 1.793 ms | 99.92% lower |
| Maximum wake-up jitter | 2259.947 ms | 1.793 ms | 99.92% lower |
| Misses above 1 ms | 300/300 | 37/300 | 87.67% lower |

## Per-run evidence

| Arm | Run | Mean | P99 | P99.9 / max | >1 ms | YOLO inference | lower-priority services |
|---|---|---:|---:|---:|---:|---:|---:|
| RR | rr-01 | 1135.365 ms | 2295.381 ms | 2312.165 ms / 2312.165 ms | 300/300 | 22.197 s | n/a |
| RR | rr-02 | 1136.717 ms | 2247.128 ms | 2259.947 ms / 2259.947 ms | 300/300 | 22.452 s | n/a |
| RR | rr-03 | 1061.209 ms | 2214.693 ms | 2250.601 ms / 2250.601 ms | 300/300 | 23.073 s | n/a |
| FP-RR | fp-rr-01 | 0.957 ms | 1.553 ms | 1.616 ms / 1.616 ms | 36/300 | 22.437 s | 90 |
| FP-RR | fp-rr-02 | 0.961 ms | 1.595 ms | 1.793 ms / 1.793 ms | 37/300 | 23.001 s | 92 |
| FP-RR | fp-rr-03 | 1.020 ms | 1.608 ms | 6.238 ms / 6.238 ms | 50/300 | 23.366 s | 83 |

The P99 ratio is the supported near-10x claim. P99.9 and maximum are reported separately and must not be described as having the same improvement ratio.
