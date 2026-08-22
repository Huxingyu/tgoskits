# StarryOS Task 1/2/3 completion assessment

Date: 2026-08-22

This report evaluates the final StarryOS system. Linux results are reference
evidence only; StarryOS is not required to reproduce every Linux number.

## 1. Task 1: real-time scheduler result survives StarryOS

### Experiment

- StarryOS vCPU0 and Zephyr vCPU0 share pCPU1.
- StarryOS has host priority 89 and runs a real in-Guest ncnn/YOLO inference.
- Zephyr has host priority 90 and captures 300 wake-ups at a 10 ms period.
- The only A/B variable is AxVisor `rr-scheduler` versus bounded
  `fp-rr-scheduler`.
- Three RR/FP-RR pairs run in the order `RR, FP-RR` repeated three times.
- The same A/B also runs with an RT-Thread companion probe (300 samples,
  10 ms period, three pairs), sharing the same pCPU1 topology.

| Metric (median of three runs) | RR | bounded FP-RR | Result |
|---|---:|---:|---:|
| Mean wake-up jitter | 9.505 ms | 0.566 ms | 16.79x lower |
| P99 wake-up jitter | 12.498 ms | 0.646 ms | **19.35x / 94.83% lower** |
| P99.9 wake-up jitter | 12.883 ms | 0.671 ms | 19.20x / 94.79% lower |
| Maximum wake-up jitter | 12.883 ms | 0.671 ms | 19.20x / 94.79% lower |
| Samples later than 1 ms | 300/300 | 0/300 | 100% fewer |

All six runs completed a real YOLO inference. FP-RR inference times were
16.761 s, 21.167 s and 21.535 s. Its bounded lower-priority service path ran
49, 70 and 97 times. The improvement therefore does not come from starving
the lower-priority StarryOS Guest.

The same A/B with the RT-Thread companion probe (three pairs) also passes:

| Metric (median of three runs) | RR | bounded FP-RR | Result |
|---|---:|---:|---:|
| Mean wake-up jitter | 23.465 ms | 0.980 ms | 95.82% lower |
| P99 wake-up jitter | 39.737 ms | 1.662 ms | **23.9x / 95.82% lower** |
| P99.9 / maximum | 43.051 ms | 1.803 ms | 95.81% lower |
| Samples later than 1 ms | 300/300 | 62/300 | 79.33% fewer |
| YOLO inference (median) | 22.266 s | 22.872 s | +2.7% |

The RT-Thread probe uses the AArch64 virtual timer (`CNTVCT_EL0`/
`CNTV_CVAL_EL0`), exposed to the RT-Thread guest through its GIC handler slot
in the periodic build; AxVisor already delivers the CNTV PPI through its VGIC
(the same path Zephyr uses). Deadlines are relative-period anchored so the
metric is per-wake scheduling delay, matching the Zephyr probe's jitter
definition. This brings RT-Thread's FP-RR floor to ~1.7 ms, close to
Zephyr's ~0.65 ms. Under RR, RT-Thread's per-wake delay is ~20-40 ms P99
because the shared vCPU is serviced in RR slices while StarryOS runs YOLO;
FP-RR reduces it to ~1-2 ms. The bounded lower-priority service path is
still exercised (87-93 services) and YOLO inference is essentially unchanged.

The supported claim is that bounded FP-RR retains and exceeds the earlier
near-10x P99 improvement under the final StarryOS + YOLO workload. It remains
a QEMU software-in-the-loop result, not a physical-board WCET bound. The same
direction holds for the RT-Thread companion probe (23.9x P99 reduction with
no inference regression, FP-RR floor ~1.7 ms).

Evidence: `results/starryos-task1-periodic-yolo-986fcf5ae-20260822/` at
revision `986fcf5ae5198bbc66d9926dbb0b201d3ad7f32c`, and
`results/starryos-task1-periodic-rtthread-20260822/`.

## 2. Task 2: T2N1 wire format and runtime proof

T2N1 uses network byte order (Big-Endian) and a fixed 28-byte header. Unlike
TCP, it has no header-length/data-offset field. The payload always starts at
byte offset 28; the field at byte 20 is the payload length.

```text
T2N1 fixed header (32 bits per row)

 Bit       0               7 8              15 16             23 24             31
          +-----------------+-----------------+-----------------+-----------------+
 Byte  0  |                         Magic = "T2N1"                               |
          +-----------------+-----------------+-----------------------------------+
 Byte  4  |   Version = 1   |      Kind       |              Flags              |
          +-----------------+-----------------+-----------------------------------+
 Byte  8  |                           Session ID                                  |
          +-----------------------------------------------------------------------+
 Byte 12  |                            Sequence                                   |
          +-----------------------------------------------------------------------+
 Byte 16  |                         Acknowledgement                               |
          +-----------------------------------+-----------------------------------+
 Byte 20  |          Payload length           |            Error code             |
          +-----------------------------------+-----------------------------------+
 Byte 24  |                              CRC32                                    |
          +-----------------------------------------------------------------------+
 Byte 28  |                         Payload (0..1200 B)                            |
          +-----------------------------------------------------------------------+
```

Field meanings:

| Offset | Size | Field | Meaning |
|---:|---:|---|---|
| 0 | 4 | Magic | ASCII `T2N1` |
| 4 | 1 | Version | Current version `1` |
| 5 | 1 | Kind | `1 CONTROL`, `2 STATUS`, `3 ERROR`, `4 ACK`, `5 HEARTBEAT` |
| 6 | 2 | Flags | Bit 0 is the reliable flag; other bits must be zero |
| 8 | 4 | Session ID | Stable identity for one protocol session |
| 12 | 4 | Sequence | Nonzero sequence for reliable CONTROL/STATUS |
| 16 | 4 | Acknowledgement | Sequence acknowledged by ACK/ERROR |
| 20 | 2 | Payload length | Number of bytes after the 28-byte header, maximum 1200 |
| 22 | 2 | Error code | `0 None`, `1 InvalidParameter`, `2 OutOfOrder`, `3 UnsupportedMessage`, `4 SessionMismatch` |
| 24 | 4 | CRC32 | CRC32 of the whole datagram with these four bytes treated as zero |

```text
CONTROL payload (12 bytes)                 STATUS payload (12 bytes)

 Bit       0               7 8              15 16             23 24             31
          +-----------------+-----------------------------------+  +-----------------+-----------------+-----------------------------------+
 Byte  0  |     Action      |          Reserved = 0             |  |      State      |      Flags      |          Reserved = 0             |
          +-----------------+-----------------------------------+  +-----------------+-----------------+-----------------------------------+
 Byte  4  |                    Signed value                      |  |                    Signed value                      |
          +-------------------------------------------------------+  +-------------------------------------------------------+
 Byte  8  |                     Request ID                       |  |              Last CONTROL request ID                 |
          +-------------------------------------------------------+  +-------------------------------------------------------+
```

CONTROL actions are `SetOutput=1`, `Stop=2`, `Reset=3`; STATUS states are
`Active=1`, `Stopped=2`, `Safe=3`. HEARTBEAT carries one 64-bit monotonic
uptime value.

Seven StarryOS + Zephyr runtime scenarios pass both dual-pcap verification and
semantic log verification: normal, one dropped ACK, retry exhaustion,
out-of-order input, invalid parameter, blackout/Safe/recovery, and model
rejection. The normal capture contains 20 verified T2N1 frames: 3 CONTROL,
6 ACK, 3 STATUS and 8 HEARTBEAT. Retry exhaustion contains the initial CONTROL
plus five retries and demonstrates Safe entry and recovery.

Evidence: `results/starryos-task123-final-db42f6168-20260822/task23/`.

## 3. Task 3: StarryOS ncnn + YOLO application

Task 3 is a real application inside the AArch64 StarryOS Guest, not host-side
inference or fixture replay. It uses pinned ncnn revision
`946fe3fb14a8dff8c06df763f67be522167b2f00`, YOLO11n ncnn parameter/weight
files, a pinned PPM input, RGB resize to 640x640, `1/255` normalization and one
ncnn thread.

| Proof | Measured result |
|---|---|
| StarryOS inference samples | 3 |
| Inference min / median / mean / max | 16.413 / 16.789 / 16.734 / 17.000 s |
| Detection | class 75, confidence 843/1000, center 421/1000, area 63/1000 |
| Controller output | bounded target 421 |
| Closed loop | 3 CONTROL messages each completed ACK + STATUS |
| CONTROL-to-STATUS RTT | 101 ms, 387 ms, 468 ms |

The separate Linux reference path now keeps T2N1 alive while inference runs:
its measured RTTs are 365 ms and 84 ms with no retry exhaustion or OutOfOrder
event. That comparison is supporting evidence; the completion claim above is
for StarryOS.

Evidence:

- `results/starryos-task123-final-db42f6168-20260822/`
- `results/starryos-task123-followup-d2efbb7a6-20260822/`

## 4. Conservative score estimate

This is an internal estimate, not an official score.

| Category | Maximum | Defensible now | Plausible upper | Remaining uncertainty |
|---|---:|---:|---:|---|
| Task 1 real-time RTOS work | 30 | 27 | 28 | No physical-board WCET; literal upstream `dev` cannot run the current assets |
| Task 2 Guest networking | 25 | 25 | 25 | Complete seven-scenario StarryOS evidence |
| Task 3 AI control loop | 25 | 25 | 25 | Complete real in-Guest ncnn/YOLO loop |
| Engineering and documentation | 15 | 13 | 14 | Submission video, final PR and remote replay remain delivery risks |
| Innovation and extensibility | 5 | 4 | 5 | Final point is evaluator-dependent |
| Main score | 100 | **94** | **97** | 3-point range |
| StarryOS replaces Linux bonus | 4 | **4** | **4** | Requires evaluator acceptance of the demonstrated replacement loop |
| StarryOS syscall work merged to `dev` | 4 | **0** | **0** | No qualifying merged syscall contribution evidence |
| Multiple RTOSes or boards | 2 | **2** | **2** | Zephyr and RT-Thread both evidenced on QEMU; physical board remains follow-up |
| Total | 110 | **100** | **103** | Expected range `100-103/110` |

Points that cannot currently be claimed are the 4-point merged StarryOS
syscall bonus. Main-score deductions are also likely for missing physical-board
hard-real-time proof, literal official `dev` runtime comparison, and unfinished
submission packaging such as video or PR replay. Full MSI-X passthrough is not
part of the stable final setup; the current NVMe path intentionally uses
`msix_qsize=1` and legacy INTx.
