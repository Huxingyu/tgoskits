# T3.1 vIRQ Overload Replay

This deterministic replay applies one arrival/service schedule to the old Git revision's unbounded queue contract and the current capacity-64 contract. It is a queue-bound proof, not an end-to-end QEMU latency measurement.

| model | accepted | overflow | max depth | p99 latency (us) | max latency (us) |
|---|---:|---:|---:|---:|---:|
| old unbounded | 2000 | 0 | 1901 | 1881050 | 1900050 |
| current bounded | 163 | 1837 | 64 | 64000 | 64000 |

The bounded implementation turns excess load into an explicit error and keeps resident queue depth at 64. The unbounded implementation accepts every edge and lets backlog and drain time grow with overload duration.
