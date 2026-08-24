# ATK-DLRK3588 native Zephyr evidence, 2026-08-24

This directory closes the previously missing physical native-RTOS control for
Task 1. Zephyr 4.4.2 booted directly as BL33 on the RK3588 board and completed
both a timer acceptance test and the 300-sample periodic-latency probe.

## Acceptance

The final boot path was:

```text
Maskrom -> RK3588 RAMBOOT loader -> upstream TF-A BL31 -> Zephyr BL33 at EL1NS
```

The timer acceptance log reaches:

```text
ATK_SLEEP_1 before=0 after=1010 delta=1010
ATK_SLEEP_2 before=1010 after=2020 delta=1010
ATK_SLEEP_3 before=2020 after=3030 delta=1010
ATK_TIMER_ACCEPT_PASS
```

The periodic log contains one header, sequences 0 through 299, and the terminal
marker `PERIODIC LATENCY COMPLETE samples=300`. The extracted CSV has 301
lines including its header.

## Native result

| Metric | Value |
|---|---:|
| Samples / period | 300 / 10 ms |
| Runtime | 3.000002041 s |
| Mean | 2.04753 us |
| P50 / P95 / P99 | 2.041 / 2.041 / 2.041 us |
| P99.9 / maximum | 4.000 / 4.000 us |
| Above 1 ms / above 10 ms | 0 / 0 |
| Sequence / monotonic errors | 0 / 0 |

See `NATIVE_VS_VIRTUALIZED.md` for the comparison and its interpretation
limits. The native-to-single-Guest difference is an end-to-end system gap, not
a pure hypervisor instruction-cost measurement. The strict contention control
is the identical Zephyr Guest binary in single- versus dual-Guest runs.

## Contents

```text
analysis/native-periodic.csv
analysis/native-vs-virtualized.csv
logs/native-periodic-console.log
logs/native-timer-acceptance-console.log
artifact-hashes.txt
SHA256SUMS.txt
```

Console logs are committed with CRLF normalized to LF for review. The original
capture identities are retained in `artifact-hashes.txt`; `SHA256SUMS.txt`
authenticates the normalized repository files.

Generated Zephyr, BL33, BL31, loader, build-tree, vendor-tool, and probe files
are deliberately excluded. Reproduce them with
`scripts/test/native-zephyr-atk-dlrk3588/` and boot with
`scripts/board/atk-dlrk3588-native-zephyr-ram-boot.sh`.

## Scope boundary

This evidence proves the native RTOS baseline only. It does not claim that
native Zephyr implements Task 2 networking or Task 3 YOLO, and it does not
replace the integrated AxVisor/StarryOS/RTOS physical evidence.
