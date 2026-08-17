# Linux Guest ftrace diagnostic gate

This run validates the optional Guest-side event trace and locates the Linux
cyclictest wakeup tail. It is a diagnostic run, not a performance A/B result:
ftrace is enabled and therefore adds observer overhead.

## Reproduction

```bash
RT_SCENARIO=stress-dedicated \
RT_DURATION_SEC=10 \
RT_LINUX_KERNEL_OVERRIDE=/home/huhu/tgoskits-rt/tmp/rt-partition/linux-trace-gcc13/linux-qemu-trace \
RT_LINUX_TRACE=events \
RT_LINUX_TRACE_BUFFER_KB=512 \
RT_RESULT_DRAIN_TIMEOUT_SEC=600 \
RT_OUTPUT_ROOT=/home/huhu/tgoskits-rt/results/task1/linux-guest-trace-gate \
RT_RUNTIME_DIAGNOSTICS=1 \
scripts/test/rt-partition/run-cyclictest.sh
```

The runner waits until the Linux console is attached before requesting the
trace dump. The Guest transfers the ring as gzip-compressed base64 so the
serial drain remains bounded. `sha256sum -c sha256sums` passes for every
archived input and result.

## Result

The analyzer matched 1,627 complete RT cyclictest wakeup chains and rejected
10 self-wakeups where the 1 ms hrtimer expired while cyclictest was already
running. No matched chain is incomplete.

| Guest segment | P50 | P99 | P99.9 | Max |
|---|---:|---:|---:|---:|
| arch timer IRQ to hrtimer callback | 14 us | 73 us | 118 us | 250 us |
| hrtimer callback to `sched_wakeup` | 18 us | 30 us | 96 us | 98 us |
| `sched_wakeup` to `sched_switch` | 208 us | 695 us | 1,205 us | 1,316 us |
| arch timer IRQ to `sched_switch` | 250 us | 727 us | 1,243 us | 1,347 us |

The corresponding trace-enabled cyclictest run reports P99 1,390 us and
P99.9 2,092 us, with three histogram overflows and a 305,000 us observed max.
The max is a TCG/host scheduling outlier and is not a WCET claim.

Among the observable Guest stages, `sched_wakeup` to actual task dispatch is
the dominant P99 component: 695 / 727 us, or 95.6% of IRQ-to-switch latency.
The trace does not yet measure the interval from the programmed timer deadline
to Guest IRQ entry. The next diagnostic step is Linux `timerlat`, which must
separate IRQ latency from thread latency before another AxVisor timer/IRQ
mechanism is selected.
