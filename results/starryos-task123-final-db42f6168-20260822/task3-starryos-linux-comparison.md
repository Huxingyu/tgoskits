# Task 3: StarryOS versus Linux Guest ncnn/YOLO

Git revision: `db42f616846f601dac641a125491593629033e97`

Both paths performed real inference inside an AArch64 Guest. Neither result is
fixture replay or host inference. They used ncnn revision
`946fe3fb14a8dff8c06df763f67be522167b2f00`, the same YOLO11n ncnn parameter,
weight and PPM input hashes, RGB resize to 640x640, `1/255` normalization, one
ncnn thread, and policy bounds 600/10/100.

| Guest | samples | inference min | median | mean | max | detection |
|---|---:|---:|---:|---:|---:|---|
| StarryOS | 3 | 16.413261 s | 16.788714 s | 16.734088 s | 17.000290 s | class 75, confidence 843, center 421, area 63 |
| Linux | 2 | 16.266994 s | 16.323816 s | 16.323816 s | 16.380638 s | class 75, confidence 843, center 421, area 63 |

The StarryOS samples are from the clean `normal` scenario. All three CONTROL
messages completed ACK/STATUS loops with observed RTTs of 101, 387 and 468 ms.
The Linux run completed one CONTROL/ACK/STATUS loop with an observed RTT of
18,891 ms. Its second CONTROL reached five retransmissions and then received
repeated `OutOfOrder` errors before recovery. Both Linux and Zephyr pcaps pass
the T2N1 verifier.

The 2.5% mean inference-time difference is only a QEMU observation from two
small, non-interleaved samples; it is not a performance claim. The Linux run's
large protocol delay also shows that these QEMU software-in-the-loop results do
not establish physical-board latency, WCET, scheduler superiority, or network
real-time guarantees.

Evidence:

- StarryOS: `task23/normal/`
- Linux: `linux-yolo/`
