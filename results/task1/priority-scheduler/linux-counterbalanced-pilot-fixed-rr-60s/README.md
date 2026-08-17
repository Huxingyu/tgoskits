# Linux counterbalanced scheduler pilot

Date: 2026-08-17

This diagnostic pair reverses the order used by the final three-round
experiment. Fixed priority ran first and round robin ran second, with otherwise
identical settings:

- `stress-noiso`, `dedicated_cpus=none`;
- pCPU1 host burner, 10 ms busy / 53 ms sleep;
- 60-second Linux cyclictest request and 300 Zephyr samples;
- runtime diagnostics enabled;
- fixed priority uses kick worker 91, vCPU 90, and timer worker 89.

Both runs completed cyclictest, stress-ng, the Zephyr sample set,
`RT_INIT_DONE`, and `PSCI_SYSTEM_OFF`.

## Results

| Metric | Fixed first | RR second | Observation |
|---|---:|---:|---|
| Linux average | 675 us | 790 us | fixed 14.56% lower |
| Linux P99 | 1178 us | 1362 us | fixed 13.51% lower, 1.156x |
| Linux P99.9 | 1900 us | 1661 us | fixed 14.39% higher |
| Linux maximum | 303498 us | 300643 us | effectively unchanged |
| Zephyr P99 | 0.914 ms | 10.585 ms | fixed 11.580x lower |
| Zephyr misses above 1 ms | 2/300 | 53/300 | fixed 96.23% fewer |

The formal `RR -> fixed` ABABAB result showed Linux P99 moving in the opposite
direction (1095 us to 1207 us). This reverse-order pair therefore invalidates a
causal claim that fixed priority either improves or regresses Linux P99 by
about 10%. The Linux difference is currently smaller than order and QEMU TCG
drift. Zephyr keeps the same large direction and magnitude, so its scheduling
result remains repeatable.

The runtime snapshots also show that timer work is complete on both sides, but
the amount of guest progress and timer activity differs substantially between
runs. This is another reason not to tune timer-worker priority from the Linux
P99 aggregate alone. The next Linux experiment must counterbalance scheduler
order across repeated pairs and trace virtual-timer deadline, worker wake,
target-vCPU wake, guest re-entry, and IRQ injection timestamps separately.

This directory intentionally archives only text and CSV evidence, not copied
guest images or AxVisor binaries. Each side's `meta.txt` records the repository
HEAD identifier and exact guest command line, but the worktree was dirty, so
this pilot is diagnostic evidence rather than a standalone reproducible build.
