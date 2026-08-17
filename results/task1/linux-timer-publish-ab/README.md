# Timer callback PPI publication pilot

This is a diagnostic pilot for the AArch64 architectural timer callback order.
The callback now publishes the expired timer PPI before waking the vCPU task:

```text
timer callback -> publish VGIC PPI level -> notify vCPU
```

The previous order only notified the task; the saved timer level was then
visible after a later VM-exit synchronization. The change is semantically
necessary for a wake-up to carry the already-expired timer state into the next
VGIC load.

The pilot held `aarch64_virtual_timer_only=0`, `dedicated_cpus=1,3`, the
diagnostic Linux kernel, timerlat trace, and all Guest/Host load parameters
constant. It compares the new binary with the archived pre-change B3 run:

| run | code | IRQ P50 | IRQ P90 | IRQ P99 | thread P99 |
|---|---|---:|---:|---:|---:|
| `results/task1/linux-wfi-pervcpu-ab/baseline-run-03` | pre-change | 263.680 us | 553.664 us | 897.744 us | 1425.952 us |
| `results/task1/linux-timer-publish-ab/modified-pilot` | PPI-before-wake | 418.672 us | 774.400 us | 1101.840 us | 1639.408 us |

This is one cross-time pilot, not a balanced performance A/B. It does not
establish an improvement; the new ordering remains a correctness fix and is
not assigned a percentage or speedup. The pilot archive has a complete
`sha256sum -c sha256sums` result. Further performance work should target the
Guest IRQ-to-thread tail and the `sched_wakeup -> sched_switch` segment already
identified by event tracing.
