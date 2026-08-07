# Day5 dual-Guest latency results

These CSV files are derived from the raw dual-Guest logs produced on 2026-08-07.
The Zephyr sampler ran for 300 10 ms periods while Linux ran with two vCPUs.

| File | Linux evidence in the same run | Samples | Mean jitter | p99 | p99.9 / max | Deadline misses |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `axvisor-dual-idle.csv` | Linux boot, `SMP: Total of 2 processors activated` | 300 | 253.909 µs | 349.872 µs | 1.344224 ms | 300 |
| `axvisor-dual-stress.csv` | Linux boot, `SMP: Total of 2 processors activated`, `LINUX STRESS START workers=2` | 300 | 197.215 µs | 316.304 µs | 869.792 µs | 300 |

Statistics were generated with:

```bash
python3 scripts/test/rt_latency_stats.py results/day5/axvisor-dual-idle.csv
python3 scripts/test/rt_latency_stats.py results/day5/axvisor-dual-stress.csv
```

The corresponding log assertions are:

```bash
rg -F 'Booting Linux' results/day5/axvisor-dual-idle.log
rg -F 'SMP: Total of 2 processors activated' results/day5/axvisor-dual-idle.log
rg -F 'LINUX STRESS START workers=2' results/day5/axvisor-dual-stress.log
rg -F 'PERIODIC LATENCY COMPLETE samples=300' results/day5/axvisor-dual-{idle,stress}.log
! rg -F 'DMA coherent allocation' results/day5/axvisor-dual-{idle,stress}.log
```

The raw logs are archived as `axvisor-dual-idle.log` and
`axvisor-dual-stress.log` (captured originally as
`/tmp/day5-dual-idle-fixed.log` and `/tmp/day5-dual-stress-fixed.log`). Their output streams interleave Linux,
AxVisor, and Zephyr bytes, so four rows were reconstructed rather than copied
as clean physical lines:

| File | Sequence | Reconstructed row |
| --- | ---: | --- |
| idle | 5 | `5,60199760,76007040,76206800,199760` |
| idle | 14 | `14,150291856,166007040,166298896,291856` |
| idle | 53 | `53,540284832,556007040,556291872,284832` |
| stress | 12 | `12,130238496,148008768,148247264,238496` |

For each recovered row, the candidate was uniquely identified in the bytes
between its neighboring intact sequence rows using the sampler invariants
`timestamp_ns = (sequence + 1) * 10_000_000 + jitter_ns` and
`actual_ns = deadline_ns + jitter_ns`; all candidates use the 16 ns timer
quantum.  The final CSVs cover exactly sequence `0..299`, contain no duplicate
sequence, and satisfy both invariants for every row.

The strict deadline rule in `rt_latency_stats.py` counts every sample as late
because the sampler records positive lateness against an absolute release
deadline.  It is retained unchanged for comparison with the Day4 baselines;
the latency conclusions use the jitter distribution and tail values.

Evidence in the stress log also includes `PERIODIC LATENCY COMPLETE samples=300`
and no `DMA coherent allocation ... quarantined` message.  The idle Linux
`/bin/sh` exits without interactive input and can panic the guest afterwards;
that does not invalidate the preceding boot/SMP/periodic-sampler evidence.

Both VM configurations use `interrupt_mode = "passthrough"`; Zephyr forwards
`/timer` and runs only on pCPU 3, while Linux uses pCPUs 1 and 2.  Consequently
these measurements are valid for the dual-Guest startup/workload evidence and
for ruling out Linux-induced shared-core scheduler contention, but they do not
exercise AxVisor's software vIRQ queue or VM timer wheel.  A real-time code
change must first use a workload that covers the selected path and add its
deterministic regression test.

## Hashes

```text
7d5c179e7e38970498c41863edabd8a33a4c10023863024339d0f0422c5aaa70  results/day5/axvisor-dual-idle.log
343bf96853c8c6b583c4d5384efc2aa3b313649bb68ae928ef85c5883b80df83  results/day5/axvisor-dual-stress.log
09f07674bed24c2a0300a3a82aef7758c7e5e2d4a91d3469099ef7191383eb6c  results/day5/axvisor-dual-idle.csv
1a8f1c63968aafdbb79f392149c271369cfb8ba2fd5de1bb3194ca89a9808c89  results/day5/axvisor-dual-stress.csv
```
