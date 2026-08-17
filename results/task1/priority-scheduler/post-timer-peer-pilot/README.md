# Timer-worker peer-priority pilot

Date: 2026-08-17

This pilot keeps the active-burner A/B workload and changes only the host
timer-worker priority policy after the previous run exposed Linux RCU
starvation:

- fixed-priority FIFO scheduler;
- timer worker priority equals vCPU priority (`90`), instead of `99`;
- burner is already READY before VM launch: pCPU1, 10 ms busy / 53 ms sleep;
- Zephyr runs on pCPU1; Linux vCPUs run on pCPU2/pCPU3;
- 90-second Linux workload, 300 Zephyr periodic samples, 1 ms tolerance.

The equal-priority policy lets timer service and vCPU run loops alternate in
the FIFO class. A higher-priority timer worker could remain runnable while
draining a timer stream and starve the guest housekeeping vCPU.

## Results

| Metric | RR reference | Fixed + peer timer worker | Change |
|---|---:|---:|---:|
| Zephyr P99 | 10.434 ms | 0.739 ms | 92.91% lower, 14.11x |
| Zephyr P99.9 | 10.707 ms | 2.161 ms | 79.82% lower, 4.95x |
| Zephyr maximum | 10.707 ms | 2.161 ms | 79.82% lower, 4.95x |
| Misses above 1 ms | 53/300 | 1/300 | 98.1% fewer |
| Linux cyclictest P99 | 1.025 ms | 1.140 ms | 11.2% higher |
| Linux cyclictest max | 306.726 ms | 300.679 ms | 2.0% lower |

The RR reference is the active-burner run in
`../active-burner-single-variable-ab/rr/stress-noiso/`. Fixed raw summaries
are in `fixed-priority/stress-noiso/zephyr-stats.txt` and
`cyclictest-summary.txt`.

## Stability gate

Passed. The run emitted all required markers, completed 300 Zephyr samples,
completed Linux cyclictest, ran stress-ng successfully, emitted
`RT_INIT_DONE`, and shut down through `PSCI_SYSTEM_OFF`. No RCU stall was
observed. The one Zephyr sample above 1 ms remains a tail-latency issue to
address with timer-worker batching/deferral, but the scheduler no longer
trades low jitter for a failed Linux workload.
