# StarryOS Task 1/2/3 final report

Status: **complete**

Implementation revision: `db42f616846f601dac641a125491593629033e97`

## Task 1

The existing AxVisor/ArceOS RR and bounded FP-RR mechanisms were reused; no
scheduler source or Linux scheduler was added. Both arms ran identical
StarryOS, Zephyr, ncnn/YOLO and T2N1 artifacts. RR completed 3 CONTROL/STATUS
cycles; FP-RR completed 3 and reported 192 lower-priority services. This is
QEMU software-in-the-loop liveness/timing evidence, not physical WCET evidence.

## Task 2

Seven StarryOS + Zephyr scenarios pass dual-pcap and semantic verification:
normal, dropped ACK, retry exhaustion, out of order, invalid parameter,
blackout, and model rejection. Retry exhaustion emitted the initial CONTROL
plus five retries, no CONTROL ACK, entered observable Safe state, recovered on
valid same-session traffic, and kept the Guest application alive. The T2N1 wire
format was not changed.

## Task 3

StarryOS and Linux both ran real ncnn/YOLO inside their AArch64 Guests with the
same ncnn revision, model/input hashes, preprocessing, single-thread setting and
bounded detection policy. Both produced class 75, confidence 843, center 421,
area 63. StarryOS normal inference averaged 16.734088 s over three samples;
Linux averaged 16.323816 s over two. The small sample and QEMU scheduling make
this an implementation comparison, not a benchmark.

The Linux run completed one ACK/STATUS loop but observed 18,891 ms RTT; its
second CONTROL exhausted retries and received OutOfOrder errors before
recovery. This limitation is retained rather than hidden. Both pcaps pass.

## Verification

- `task2-net-protocol`: 21 tests passed.
- `task3-model`: 11 tests passed.
- StarryOS endpoint: 6 tests passed; targeted clippy passed with `-D warnings`.
- Linux endpoint host test and current-revision cross-build passed.
- AArch64 static ncnn smoke passed with the expected detection.
- Python dual-Guest suite: 28 tests passed.
- Task 1 A/B and all seven Task 2/3 evidence directories pass their verifiers.

An additional broader workspace clippy diagnostic found that the public
`task3-ncnn::infer` unsafe API lacks a `# Safety` doc section. That optional
check is outside the specified Starry endpoint targeted clippy gate and did not
affect the retained implementation revision or runtime evidence.

All evidence is under this directory. `SHA256SUMS.txt` authenticates every
retained file other than the manifest itself.
