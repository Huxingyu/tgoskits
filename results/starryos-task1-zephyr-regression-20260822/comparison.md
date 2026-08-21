# StarryOS Task 1 scheduler A/B

Git revision: `2ab3c52285d1c48eb2785cf83b2d7ec07810ab26`

Both arms use the same StarryOS rootfs/endpoint/kernel, zephyr image, QEMU topology and shared-pCPU Guest configs. Only the AxVisor scheduler feature changes. Results are QEMU software-in-the-loop observations, not physical-board WCET bounds.

| Scheduler | CONTROL | STATUS | RTT count | min ms | median ms | p95 ms | max ms | lower-priority services |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| rr | 4 | 3 | 3 | 151 | 574 | 732 | 732 | n/a |
| fp-rr | 4 | 3 | 3 | 154 | 512 | 727 | 727 | 194 |

The p95 value uses the nearest-rank definition. Scheduler timing is reported as an observation only; the acceptance claim is that both Guests remain live and complete the same T2N1/ncnn/YOLO workload, and that the bounded FP-RR service path is exercised.
