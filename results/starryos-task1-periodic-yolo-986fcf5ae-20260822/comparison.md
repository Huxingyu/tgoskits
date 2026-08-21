# StarryOS Task 1 periodic-latency A/B

Both arms run the same in-Guest ncnn/YOLO workload on StarryOS (priority 89) while a 300-sample, 10 ms Zephyr periodic probe (priority 90) shares pCPU1. Only the AxVisor scheduler feature changes.

| Metric (median across runs) | RR | bounded FP-RR | Change |
|---|---:|---:|---:|
| P99 wake-up jitter | 12.498 ms | 0.646 ms | 19.347x / 94.83% lower |
| P99.9 wake-up jitter | 12.883 ms | 0.671 ms | 94.79% lower |
| Maximum wake-up jitter | 12.883 ms | 0.671 ms | 94.79% lower |
| Misses above 1 ms | 300/300 | 0/300 | 100.00% lower |

## Per-run evidence

| Arm | Run | Mean | P99 | P99.9 / max | >1 ms | YOLO inference | lower-priority services |
|---|---|---:|---:|---:|---:|---:|---:|
| RR | rr-01 | 11.091 ms | 15.679 ms | 15.680 ms / 15.680 ms | 300/300 | 20.677 s | n/a |
| RR | rr-02 | 9.505 ms | 12.498 ms | 12.883 ms / 12.883 ms | 300/300 | 20.785 s | n/a |
| RR | rr-03 | 5.520 ms | 5.808 ms | 7.983 ms / 7.983 ms | 300/300 | 20.831 s | n/a |
| FP-RR | fp-rr-01 | 0.566 ms | 0.618 ms | 0.671 ms / 0.671 ms | 0/300 | 16.761 s | 49 |
| FP-RR | fp-rr-02 | 0.560 ms | 0.646 ms | 0.662 ms / 0.662 ms | 0/300 | 21.167 s | 70 |
| FP-RR | fp-rr-03 | 0.588 ms | 0.704 ms | 0.735 ms / 0.735 ms | 0/300 | 21.535 s | 97 |

The P99 ratio is the supported near-10x claim. P99.9 and maximum are reported separately and must not be described as having the same improvement ratio.
