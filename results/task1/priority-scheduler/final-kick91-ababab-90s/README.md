# Final fixed-priority scheduler A/B

Date: 2026-08-17

This is the final repeated scheduler experiment after fixing the Linux SMP
liveness failure. It supersedes the single-pair result in
`formal-peer-timer-ab`, including that directory's 18.07x Zephyr figure and its
claim that timer-worker priority 89 alone fixed liveness.

## Mechanism under test

The experiment compares the round-robin and fixed-priority FIFO host
schedulers without changing guest placement, memory, devices, images, or
offered load. Both sides use the same production priority contract:

- deferred interrupt-controller vCPU kick worker: priority 91;
- guest vCPU run loops and periodic vIRQ injector: priority 90;
- per-CPU timer worker: priority 89.

Architecture-controller interrupts now wake only their target vCPU. The
priority-91 deferred kick worker closes the dependency between a published VGIC
interrupt and a target vCPU sleeping in no-deadline WFI. Without that ordering,
a running priority-90 vCPU could wait for a remote guest CPU while preventing
the priority-0 kick worker from waking it: a fixed-priority inversion, not a
CPU-partitioning failure.

## Protocol

- order: `RR -> fixed`, interleaved for three rounds (`ABABAB`);
- Linux workload: 90 seconds per run, two vCPUs on pCPU2/pCPU3;
- Zephyr: pCPU1, 300 periodic samples per run;
- host burner: pCPU1, 10 ms busy / 53 ms sleep;
- scenario: `stress-noiso`, `dedicated_cpus=none`;
- all six runs use commit `db5132f40a6f901dd48cb2af146edcab868a733c`.

All six runs completed the Zephyr sample set, Linux cyclictest and stress-ng
workload, `RT_INIT_DONE`, and `PSCI_SYSTEM_OFF`. No progress watchdog or RCU
stall was observed. The fixed-priority runs all crossed the earlier freeze
point near 100 seconds of guest uptime.

## Results

Values below are medians across the three runs of each scheduler unless noted.

| Metric | Round robin | Fixed priority | Change |
|---|---:|---:|---:|
| Zephyr P99 jitter | 10.721 ms | 1.022 ms | 90.47% lower, 10.494x |
| Zephyr P99.9 / max | 11.195 ms | 1.093 ms | 90.24% lower by median |
| Zephyr misses above 1 ms | 56/300 | 5/300 | 91.07% fewer |
| Linux cyclictest average | 699 us | 742 us | 6.15% higher |
| Linux cyclictest P99 | 1095 us | 1207 us | 10.23% higher |
| Linux cyclictest P99.9 | 1762 us | 1824 us | 3.52% higher |
| Linux cyclictest maximum | 304000 us | 303857 us | effectively unchanged |

Zephyr P99 is repeatable across the three fixed-priority runs (0.914-1.495 ms)
versus round robin (10.683-10.792 ms). However, fixed-priority run 02 contains
a 10.775 ms P99.9/maximum outlier. The worst observed value across all three
runs therefore improves only 4.33% (11.263 ms to 10.775 ms), not one order of
magnitude. The defensible claim is a 10.494x Zephyr P99 improvement and a
91.07% reduction in 1 ms misses, not a cross-run worst-case bound.

Linux cyclictest does not improve in this formal experiment. Its P99 regresses
by 10.23%, and the approximately 304 ms maximum remains. However, the
reverse-order 60-second diagnostic pair in
`../linux-counterbalanced-pilot-fixed-rr-60s` reverses the P99 sign: fixed
priority is 13.51% lower than RR there. The defensible cross-experiment
conclusion is therefore that no repeatable Linux P99 improvement or regression
has yet been established. This sets the next target: counterbalanced repeats
plus separate Linux guest scheduling, virtual-timer, and interrupt tail-latency
tracing under the same topology. Static CPU partitioning is neither the
variable nor an explanation for the result in this directory.

Machine-readable protocol and aggregates are in `protocol.txt` and
`comparison.txt`. Per-run raw logs, CSV files, manifests, and checksums remain
under `rr/run-*` and `fixed-priority/run-*`.
