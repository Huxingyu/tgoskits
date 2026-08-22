# StarryOS Task 1 periodic-latency A/B

Both arms run the same in-Guest ncnn/YOLO workload on StarryOS (priority 89) while a 300-sample, 10 ms RT-Thread periodic probe (priority 90) shares pCPU1. Only the AxVisor scheduler feature changes.

| Metric (median across runs) | RR | bounded FP-RR | Change |
|---|---:|---:|---:|
| P99 wake-up jitter | 5533.214 ms | 2.230 ms | 2480.781x / 99.96% lower |
| P99.9 wake-up jitter | 5598.311 ms | 5.633 ms | 99.90% lower |
| Maximum wake-up jitter | 5598.311 ms | 5.633 ms | 99.90% lower |
| Misses above 1 ms | 300/300 | 13/300 | 95.67% lower |

## Per-run evidence

| Arm | Run | Mean | P99 | P99.9 / max | >1 ms | YOLO inference | lower-priority services |
|---|---|---:|---:|---:|---:|---:|---:|
| RR | rr-01 | 2827.846 ms | 5533.214 ms | 5598.311 ms / 5598.311 ms | 300/300 | 18.626 s | n/a |
| FP-RR | fp-rr-01 | 0.235 ms | 2.230 ms | 5.633 ms / 5.633 ms | 13/300 | 89.756 s | 426 |

The P99 ratio is the supported near-10x claim. P99.9 and maximum are reported separately and must not be described as having the same improvement ratio.
