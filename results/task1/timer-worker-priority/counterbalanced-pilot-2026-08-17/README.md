# Bounded timer-worker priority pilot

This pilot tests one AxVisor software mechanism while holding the Guest,
topology, timer contract, WFI policy, and load fixed. The baseline keeps the
per-CPU timer worker at priority 89. The modified build raises it to priority
91, equal to the deferred vCPU kick worker and one level above the priority-90
vCPU, while limiting each worker wake to one expired callback.

## Why this experiment was selected

The preceding IRQ/worker observer usually reported no IRQ association even
though hardware IRQ and worker-wake counts were nonzero. Source inspection
showed that the timestamp was not lost by `IrqNotify`: after the IRQ woke the
priority-89 worker, the priority-90 vCPU resumed first and synchronously called
`check_timer_events()`, consuming the expired event before the worker ran. A
single timestamp consumed only by the worker therefore observed the wrong
consumer and could not produce a valid deadline-to-IRQ-to-worker split.

The invalid association counters and histograms were removed. The retained
`expiry_late_*` distribution measures the valid deadline-to-actual-callback
boundary regardless of whether the callback is consumed by the vCPU path or
the worker path. The common timer callback now wakes the AxVM worker only when
the published AxVM deadline is actually due; this correctness-preserving
filter is present on both sides of the A/B and is not counted as the priority
mechanism's benefit.

## Protocol

Two 30-second pairs were run in counterbalanced order:

```text
baseline, modified, modified, baseline
```

Both sides used:

- Linux vCPU0 on pCPU2 and vCPU1 on pCPU3.
- `dedicated_cpus=1,2,3`.
- CNTV-only timer contract and trapped WFI.
- Fixed-priority FIFO scheduling.
- Linux timerlat and cyclictest on Guest CPU1 with stress-ng on Guest CPU0.
- The same trace-enabled Linux kernel and Zephyr control image.

Raw runs are in the sibling `pilot-2026-08-17` and
`reverse-pilot-2026-08-17` directories. `comparison.txt` combines both pairs.

## Results

Positive percentages mean lower latency in the priority-91 build. Medians are
the midpoint of the two runs per side; pair columns retain the run direction.

| Metric | Priority 89 | Bounded priority 91 | Median change | Pair 1 | Pair 2 |
|---|---:|---:|---:|---:|---:|
| Host expiry P99 | 188.5 us | 189.5 us | 0.53% worse | 10.48% better | 14.37% worse |
| Host expiry P99.9 | 266 us | 236 us | 11.28% better | 20.42% better | 0.81% better |
| timerlat IRQ P99 | 534.920 us | 554.560 us | 3.67% worse | 7.26% better | 18.42% worse |
| timerlat thread P99 | 1237.504 us | 1045.848 us | 15.49% better | 21.64% better | 8.02% better |
| IRQ-to-thread P99 | 786.344 us | 671.616 us | 14.59% better | 23.35% better | 3.24% better |
| cyclictest P99 | 1632.5 us | 1578.5 us | 3.31% better | 6.76% better | 0.31% worse |
| cyclictest P99.9 | 2295.5 us | 1850.5 us | 19.39% better | 30.06% better | 6.38% better |
| cyclictest max | 306.928 ms | 305.952 ms | 0.32% better | 0.40% better | 0.24% better |
| Zephyr P99 | 686.752 us | 699.400 us | 1.84% worse | 15.91% better | 25.77% worse |
| Zephyr P99.9/max | 710.056 us | 758.280 us | 6.79% worse | 11.88% better | 31.47% worse |

Both modified runs completed without an RCU stall, watchdog timeout, or Guest
liveness failure. However, the first modified run recorded a pCPU3 timer-wheel
maximum lock wait of 61.730 ms; the second recorded 83.808 us. Baseline values
were 92.224 us and 184.896 us. The isolated spike is not repeatable evidence of
a regression, but it is a credible priority-inversion risk because remote
timer cancellation can hold a per-CPU wheel lock while the higher-priority
worker spins without priority inheritance.

## Decision

The priority-91 worker does not consistently improve the mechanism boundary it
was chosen to fix: Host expiry P99 and timerlat IRQ P99 reverse direction, and
Zephyr P99 also reverses. Linux thread P99 and P99.9 improve in both pairs, but
that effect appears after Guest IRQ delivery and cannot be independently
attributed to faster Host timer expiry. Cyclictest P99 is not directionally
stable and max is effectively unchanged.

Therefore `timer-worker-priority-boost` remains measurement-only and disabled
by default. It does not enter formal repetition or long-duration testing and
is not counted as a Task 1 performance improvement. The Linux tail-latency
investigation stops here; further final work should consolidate the already
validated WFI, fixed-priority preemption, and per-CPU timer-wheel results.
