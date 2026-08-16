# Task1 One-Hour Stability Result

The accepted run is `stress-rt/`, using the same RT partition topology as the
formal matrix with `RT_DURATION_SEC=3600`.

## Acceptance

- runner exit code: 0
- Linux cyclictest samples: 3,347,556
- guest elapsed time: 3598.96 s
- guest/host progress ratio: 1.000018463
- Zephyr samples: 300/300
- pCPU1 host periodic ticks: zero in all three snapshots
- watchdog artifacts: none
- `sha256sum -c stress-rt/sha256sums`: all pass

## Timing Summary

| Source | Mean | P90 | P95 | P99 | P99.9 | Max |
|---|---:|---:|---:|---:|---:|---:|
| Linux cyclictest | 679 us | 872 us | 950 us | 2061 us | 9212 us | 304760 us |
| Zephyr jitter | 728.577 us | 919.680 us | 965.056 us | 1072.384 us | 1164.672 us | 1164.672 us |

Compared with the accepted 30-minute `stress-rt` run, Linux average latency is
12.42% higher, P90 is 6.21% higher, P95 is 6.26% higher, P99 is 94.43% higher,
P99.9 is 5.95% higher, and max is 0.55% higher. The run therefore proves
functional one-hour stability and no-tick isolation, but not a stable or
improved long-tail latency distribution.

The Zephyr sampler still captures only 300 samples near workload start. Its
numbers can be compared across runs, but they cannot establish first-window
versus last-window degradation over the hour. A future stability runner needs
periodic or continuously timestamped latency windows for that claim.

## Reproduction

```bash
RT_SCENARIO=stress-rt \
RT_DURATION_SEC=3600 \
RT_OUTPUT_ROOT=results/task1/stability \
  scripts/test/rt-partition/run-cyclictest.sh

cd results/task1/stability/stress-rt
sha256sum -c sha256sums
```
