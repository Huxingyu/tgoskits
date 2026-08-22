# StarryOS Task 1 scheduler A/B

Git revision: `8171bc5e44cbf9974a373542ea07d4ac5a614133`

Both arms use the same StarryOS rootfs/endpoint/kernel, zephyr image, QEMU topology and shared-pCPU Guest configs. Only the AxVisor scheduler feature changes. Results are QEMU software-in-the-loop observations, not physical-board WCET bounds.

| Scheduler | CONTROL | STATUS | RTT count | min ms | median ms | p95 ms | max ms | lower-priority services |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| rr | 3 | 3 | 3 | 152 | 487 | 644 | 644 | n/a |
| fp-rr | 3 | 3 | 3 | 153 | 516 | 630 | 630 | 196 |

The p95 value uses the nearest-rank definition. Scheduler timing is reported as an observation only; the acceptance claim is that both Guests remain live and complete the same T2N1/ncnn/YOLO workload, and that the bounded FP-RR service path is exercised.
