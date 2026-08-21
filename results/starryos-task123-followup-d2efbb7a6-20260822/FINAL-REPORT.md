# StarryOS Task 1/2/3 follow-up report

Date: 2026-08-22
Implementation revision: `d2efbb7a6d4968ffee462d5e8cd5d1258ecc2029`
Baseline delivery: `6f3098babc6746c2a2345864dbd91753b6b7e985`
Status: complete

## Fixed issues

The Linux Guest previously ran ncnn synchronously inside the T2N1 polling
loop. One 16-second inference therefore inflated the first protocol RTT to
18,891 ms; the next request exhausted retries and produced repeated
`OutOfOrder` errors. Linux ncnn inference now runs in a one-shot background
worker while the main loop continues protocol polling. The T2N1 wire format
and the StarryOS endpoint path are unchanged.

The follow-up also documents the unsafe ncnn FFI contract and arms YOLO packet
capture before the first CONTROL transaction.

## Clean-revision result

- Real in-Guest ncnn/YOLO inference completed twice: 17,357,824 us and
  17,681,608 us.
- Both detections were class 75, confidence 843/1000, center 421/1000 and area
  63/1000. The bounded controller target remained 421.
- CONTROL-to-STATUS RTT was 365 ms and 84 ms, independent of inference time.
- Heartbeats continued throughout both long inference calls.
- Linux and Zephyr captures each contain 33 packets and 24 T2N1 frames:
  2 CONTROL, 4 ACK, 2 STATUS and 16 HEARTBEAT.
- Both captures passed the T2N1 verifier. There was no ERROR,
  `RetryExhausted`, or `OutOfOrder` event.

## Regression

- `task2-net-protocol`: 21 tests passed.
- `task3-model`: 11 tests passed.
- Dual-Guest Python tools: 28 tests passed.
- Linux endpoint test/build, YOLO control-loop check and strict clippy passed.
- AArch64 ncnn smoke passed with the same class-75 detection.

## Scope

This follow-up validates the Task 2/3 Linux Guest protocol-liveness fix and
real YOLO path. It does not rerun Task 1. The existing Task 1 evidence proves
RR and bounded FP-RR liveness plus observed QEMU timing, not universal
acceleration or physical WCET.
