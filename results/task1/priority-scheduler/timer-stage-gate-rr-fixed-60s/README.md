# Virtual-timer callback stage diagnostic

Date: 2026-08-17

This diagnostic pair extends the per-CPU timer-expiry histogram with two
feature-gated vCPU stages:

1. valid architectural-timer callback to the target vCPU leaving its WFI wait;
2. callback to the vCPU task dispatching `run_vcpu`, before architecture entry
   preparation and the hardware world switch.

The order was `fixed -> RR`; each side ran once for 60 Guest seconds from the
same dirty worktree at commit
`db5132f40a6f901dd48cb2af146edcab868a733c`. This is mechanism localization,
not a formal performance claim. Topology, Guest images, workload, host burner,
timer wheel, and runtime diagnostics were identical; only the host scheduler
changed.

Both runs completed cyclictest, stress-ng, all 300 Zephyr samples,
`RT_INIT_DONE`, and `PSCI_SYSTEM_OFF` without watchdog or RCU-stall failures.

## Linux vCPU1 stages

vCPU ID 1 is unambiguous in this dual-Guest setup because only the two-vCPU
Linux VM has a vCPU1. The existing vCPU0 counters aggregate Linux vCPU0 and the
single-vCPU Zephyr VM, so they are not used for per-Guest attribution here.

| Metric | Round robin | Fixed priority | Single-pair change |
|---|---:|---:|---:|
| pCPU3 timer expiry P99 | 205 us | 210 us | 2.44% higher |
| callback -> WFI wake P99 | 76 us | 67 us | 11.84% lower |
| callback -> WFI wake P99.9 | 104 us | 85 us | 18.27% lower |
| callback -> run dispatch P99 | 102 us | 86 us | 15.69% lower |
| callback -> run dispatch P99.9 | 160 us | 113 us | 29.38% lower |
| Linux cyclictest P99 | 1152 us | 1184 us | 2.78% higher |
| Linux cyclictest P99.9 | 1576 us | 1515 us | 3.87% lower |

Fixed-priority scheduling therefore has a directly measurable software effect
inside the Host wake/reschedule path: both callback-to-wake and
callback-to-run-dispatch tails shrink. The timer-expiry P99 remains unchanged
at roughly 0.2 ms, while Linux cyclictest P99 does not follow the Host-stage
improvement. Percentiles cannot be added algebraically, but the scale is
decisive: the measured Host stages are hundreds of microseconds below the
approximately 1.2 ms end-to-end Linux tail.

## Zephyr cross-check

| Metric | Round robin | Fixed priority | Single-pair change |
|---|---:|---:|---:|
| Zephyr P99 jitter | 10.440 ms | 1.021 ms | 90.22% lower, 10.23x |
| misses above 1 ms | 53/300 | 4/300 | 92.45% fewer |

This matches the repeated scheduler experiment and confirms that the same
fixed-priority mechanism has a large effect when a low-priority Host burner is
the dominant blocking source.

## Next boundary

The remaining Linux tail is after the Host run-dispatch boundary: architecture
entry preparation, virtual timer IRQ visibility, Linux IRQ handling, hrtimer
expiry, task wakeup, and Guest scheduling. The current Linux image has
`CONFIG_PREEMPT=y` and `CONFIG_HZ=250`, but `CONFIG_FTRACE` and
`CONFIG_NO_HZ_FULL` are disabled even though the command line contains
`nohz_full=1`. Guest-native timerlat/ftrace attribution therefore requires a
new trace-enabled kernel image; the existing command-line isolation claim must
not imply that full dynticks is active.

Raw summaries, metadata, and serial logs are retained under `rr/` and
`fixed/`. The logs contain the complete `rt stat` snapshots and histogram
overflow/max evidence.
