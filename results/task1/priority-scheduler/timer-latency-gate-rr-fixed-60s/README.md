# Timer-expiry latency diagnostic gate

Date: 2026-08-17

This single-pair diagnostic separates AxVM timer-wheel expiry lateness from
the Linux cyclictest end-to-end result. It is not a formal scheduler result:
the order is `fixed -> RR`, each side ran once for 60 Guest seconds, and both
images were built from the same dirty worktree at commit
`db5132f40a6f901dd48cb2af146edcab868a733c`.

## Controlled variables

- scenario: `stress-noiso`, with no `dedicated_cpus`;
- Linux: two vCPUs on pCPU2/pCPU3, cyclictest on Guest CPU1 and stress-ng on
  Guest CPU0;
- Zephyr and the 10 ms busy / 53 ms sleep host burner share pCPU1;
- both boards enable the per-CPU timer wheel and `timer-latency-stats`;
- the only intended A/B variable is the host scheduler: round robin versus
  fixed-priority FIFO.

Both runs completed Linux cyclictest, stress-ng, all 300 Zephyr samples,
`RT_INIT_DONE`, and `PSCI_SYSTEM_OFF` without a progress-watchdog or RCU-stall
failure.

## End-to-end results

| Metric | Round robin | Fixed priority | Single-pair change |
|---|---:|---:|---:|
| Linux cyclictest average | 675 us | 669 us | 0.89% lower |
| Linux cyclictest P99 | 1030 us | 1005 us | 2.43% lower |
| Linux cyclictest P99.9 | 1752 us | 1562 us | 10.84% lower |
| Linux cyclictest maximum | 304.521 ms | 304.250 ms | effectively unchanged |
| Zephyr P99 jitter | 10.723 ms | 0.989 ms | 90.78% lower, 10.84x |
| Zephyr misses above 1 ms | 54/300 | 3/300 | 94.44% fewer |
| Zephyr maximum | 10.948 ms | 10.550 ms | 3.64% lower |

The Zephyr result agrees with the repeated scheduler experiment: fixed-priority
preemption removes the normal busy-window delay, while a roughly 10 ms
outlier remains. The 2.43% Linux P99 difference is a diagnostic observation,
not a repeatable improvement claim.

## Timer-path result

The pCPU3 wheel owns the measured Linux vCPU's architectural-timer callbacks.
Its expiry-lateness histogram is sampled when the timer worker actually
removes an elapsed event from the wheel.

| pCPU3 timer metric | Round robin | Fixed priority |
|---|---:|---:|
| samples | 52,910 | 54,337 |
| P50 expiry lateness | 50 us | 49 us |
| P99 expiry lateness | 164 us | 191 us |
| P99.9 expiry lateness | 237 us | 291 us |
| overflow above 4.096 ms | 15 | 11 |
| maximum | 299.538 ms | 269.979 ms |

The normal timer-expiry path is therefore in the low hundreds of microseconds
on both schedulers and does not track the approximately 1 ms Linux cyclictest
P99. Fixed priority is slightly worse at timer P99 in this pair while Linux
cyclictest is slightly better, which rules out timer-wheel expiry lateness as
the explanation for the end-to-end sign. The approximately 270-300 ms maxima
and histogram overflows remain host/TCG stall observations, not an AxVisor
worst-case bound.

The next diagnostic boundary is after the timer callback: target-vCPU wake,
actual vCPU resumption, Guest entry, virtual IRQ visibility, and Linux Guest
scheduling. Raw summaries, CSV data, metadata, and `rt stat` output are kept in
`rr/` and `fixed/`; large binaries and full serial logs are intentionally not
duplicated here.
