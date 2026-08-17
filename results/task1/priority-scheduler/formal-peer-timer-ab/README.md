# Formal fixed-priority scheduler A/B

Date: 2026-08-17

> Superseded: this single A/B pair found the scheduler benefit but did not
> establish repeated Linux SMP liveness. Use
> `../final-kick91-ababab-90s/README.md` for the final three-round result. The
> final Zephyr P99 improvement is 10.494x, not 18.07x, and Linux P99 regresses
> by 10.23% in that repeated experiment.

This directory contains one complete sequential A/B pair from the same source
tree and the same experiment script. The only board-level variable is the
AxVisor host scheduler:

- `rr/stress-noiso`: round-robin scheduler;
- `fixed-priority/stress-noiso`: fixed-priority FIFO scheduler;
- both use the peer-priority timer worker policy (`timer worker = vCPU = 90`);
- burner: pCPU1, 10 ms busy / 53 ms sleep, READY before VM launch;
- Zephyr: pCPU1, 300 samples, 1 ms deadline tolerance;
- Linux: two vCPUs on pCPU2/pCPU3, stress-ng and 90-second cyclictest window.

The guest images, memory, device map, vCPU affinity, boot arguments, and
offered load are held constant. The runner accepted both cases, including
`RT_INIT_DONE`, `PERIODIC LATENCY COMPLETE samples=300`, and clean VM shutdown.

## Results

| Metric | RR | Fixed priority | Change |
|---|---:|---:|---:|
| Zephyr P99 | 10.120 ms | 0.560 ms | 94.47% lower, 18.07x |
| Zephyr P99.9 | 10.661 ms | 0.644 ms | 93.96% lower, 16.56x |
| Zephyr maximum | 10.661 ms | 0.644 ms | 93.96% lower, 16.56x |
| Zephyr misses above 1 ms | 51/300 | 0/300 | 100% fewer |
| Linux cyclictest P99 | 1.063 ms | 0.883 ms | 16.93% lower |
| Linux cyclictest maximum | 305.050 ms | 306.244 ms | within 0.4% |

This was an early independent software scheduling/preemption result. It must not be
reported as the earlier static-partition `18.29x`; that number measures CPU
topology and background-load isolation. The `18.07x` value here is retained as
the raw result of this pair, but it is superseded by the repeated final result.

## Stability

Both cases in this pair passed the 90-second Linux workload. Later repetitions
showed that timer-worker ordering alone did not fix liveness: the deferred VGIC
vCPU kick worker could still be starved at default priority 0. The final
priority contract and repeated validation are documented in the superseding
result above.
