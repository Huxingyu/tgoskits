# Post-VM-exit yield counterbalanced pilot

This experiment isolates the unconditional `yield_now()` after each completed
vCPU run. It is an AxVisor software-mechanism A/B: both sides use the same
2-vCPU Linux Guest, CPU placement, CNTV-only timer contract, trapped WFI,
trace-enabled Linux image, Zephyr control Guest, and stress load. The modified
side adds only the `no-vcpu-exit-yield` feature.

## Protocol

```bash
RT_EXIT_YIELD_AB_DURATION_SEC=30 \
RT_EXIT_YIELD_AB_REPEATS=2 \
RT_EXIT_YIELD_AB_OUTPUT_ROOT=/home/huhu/tgoskits-rt/results/task1/vcpu-exit-yield/counterbalanced-pilot-2026-08-17 \
scripts/test/rt-partition/run-vcpu-exit-yield-ab.sh
```

The counterbalanced order was `baseline, modified, modified, baseline`.
Linux vCPU0 was bound to pCPU2 and vCPU1 to pCPU3; pCPU1-3 were dedicated.
Each Linux measurement window was 30 seconds. The complete fixed inputs and
runtime settings are recorded in `protocol.txt` and each run's `meta.txt`.

The mechanism gate passed in both pairs:

- Baseline vCPU1 `post_vmexit_yields`: 101,217 and 99,750.
- Modified vCPU1 `post_vmexit_yields`: 0 and 0.
- `direct_overlaps`: 0 in all four runs.
- Host periodic scheduler ticks on pCPU1-3: 0 in all four runs.

## Results

Positive percentages mean lower latency after removing the yield. Medians are
the median of the two runs on each side, while the pair columns preserve the
counterbalanced run direction.

| Metric | Baseline median | Modified median | Median change | Pair 1 | Pair 2 |
|---|---:|---:|---:|---:|---:|
| callback to `run_vcpu` P50 | 61 us | 56 us | 8.20% better | 9.68% | 6.67% |
| callback to `run_vcpu` P99 | 112.5 us | 111.5 us | 0.89% better | 7.02% | 5.41% worse |
| direct ACK to `run_vcpu` P50 | 15 us | 9 us | 40.00% better | 40.00% | 40.00% |
| direct ACK to `run_vcpu` P99 | 29.5 us | 17.5 us | 40.68% better | 59.46% | 9.09% |
| direct ACK to `run_vcpu` P99.9 | 41.5 us | 32 us | 22.89% better | 27.27% | 17.95% |
| timerlat IRQ P99 | 557.960 us | 547.944 us | 1.80% better | 15.51% worse | 16.34% |
| timerlat thread P99 | 1299.968 us | 1256.768 us | 3.32% better | 5.90% worse | 11.54% |
| IRQ-to-thread P99 | 955.472 us | 860.144 us | 9.98% better | 8.92% worse | 25.94% |
| cyclictest P99 | 1701 us | 1723.5 us | 1.32% worse | 22.65% | 30.97% worse |
| cyclictest P99.9 | 2373 us | 3129 us | 31.86% worse | 8.22% | 80.01% worse |
| Zephyr P99 control | 695.520 us | 748.776 us | 7.66% worse | 35.28% worse | 11.41% |

`mechanism-comparison.txt` contains every per-run value, paired reduction,
group median, cyclictest max, and P99.9 timerlat segment.

## Interpretation

The unconditional yield is a real cost on the direct timer-ACK path. Removing
it reduces direct ACK-to-dispatch P50 by 40% in both pairs, P99 in both pairs,
and P99.9 in both pairs. This is independent of static CPU partitioning because
the topology is fixed across the A/B.

The callback path already has to wake and schedule a parked vCPU, so removing
the later post-exit yield does not consistently improve its P99. Linux timerlat
IRQ/thread P99 and cyclictest P99 also reverse direction between the two pairs.
The unchanged Zephyr control reverses direction as well, confirming substantial
TCG/order noise. The cyclictest max remains approximately 306 ms on both sides.

Therefore this pilot supports only the narrow statement that the host runqueue
round trip after direct timer exits was reduced. It does not support a Linux
P99, P99.9, max, or worst-case improvement claim, and it does not justify
changing the default. `no-vcpu-exit-yield` remains an opt-in measurement feature.

The next diagnostic boundary is between `run_vcpu` dispatch and actual Guest
entry, including pending-vIRQ drain, timer preparation, vCPU state transition,
and VGIC load. Current pCPU3 timer-expiry P99 is about 202-211 us and direct
ACK-to-dispatch P99 is 15-57 us, while timerlat IRQ P99 is 507-606 us. Measuring
the missing architecture-entry segment is required before selecting another
interrupt-path optimization.
