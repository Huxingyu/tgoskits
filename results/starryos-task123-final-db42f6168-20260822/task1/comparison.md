# StarryOS Task 1 scheduler A/B

Git revision: `db42f616846f601dac641a125491593629033e97`

Both arms use the same StarryOS rootfs/endpoint/kernel, Zephyr image, QEMU topology and shared-pCPU Guest configs. Only the AxVisor scheduler feature changes. Results are QEMU software-in-the-loop observations, not physical-board WCET bounds.

| Scheduler | CONTROL | STATUS | RTT count | min ms | median ms | p95 ms | max ms | lower-priority services |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| rr | 3 | 3 | 3 | 142 | 472 | 661 | 661 | n/a |
| fp-rr | 4 | 3 | 3 | 145 | 510 | 533 | 533 | 192 |

The p95 value uses the nearest-rank definition. Scheduler timing is reported as an observation only; the acceptance claim is that both Guests remain live and complete the same T2N1/ncnn/YOLO workload, and that the bounded FP-RR service path is exercised.
