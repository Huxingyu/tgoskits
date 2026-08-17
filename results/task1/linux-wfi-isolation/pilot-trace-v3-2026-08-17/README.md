# Linux timer contract / WFI three-cell pilot

This directory isolates the Linux architectural timer contract from WFI
handling with three legal cells on the same AxVisor source revision:

| Cell | Timer contract | WFI policy |
|---|---|---|
| `cntp-trap` | CNTP exposed | trapped |
| `cntv-trap` | CNTV only | trapped |
| `cntv-passthrough` | CNTV only | hardware passthrough |

All cells use the same trace-enabled Linux image, initramfs, Zephyr image,
stress workload, two-vCPU Linux placement (`vCPU0 -> pCPU2`, `vCPU1 ->
pCPU3`), and dedicated host CPU mask (`pCPU1,2,3`). The broader dedicated
mask is an experimental control: VM-wide WFI passthrough is only legal when
both Linux vCPUs have direct wake-capable dedicated pCPUs. It is not counted
as a software performance improvement.

## Pilot result

The 30-second single-repeat pilot produced:

| Metric | `cntp-trap` | `cntv-trap` | `cntv-passthrough` |
|---|---:|---:|---:|
| Linux cyclictest P99 | 1686 us | 1841 us | 1735 us |
| Linux cyclictest P99.9 | 2590 us | 2453 us | 2927 us |
| Linux cyclictest max | 306746 us | 307656 us | 307288 us |
| timerlat IRQ P99 | 563.536 us | 498.960 us | 433.008 us |
| timerlat thread P99 | 1176.512 us | 1156.464 us | 1036.528 us |
| timerlat IRQ-to-thread P99 | 765.424 us | 755.824 us | 757.568 us |
| CNTV ACK-to-dispatch P99 | 32 us | 22 us | 26 us |
| CNTV activation hold P99 | 376 us | 331 us | 401 us |
| pCPU3 WFI VM exits | 27406 | 26173 | 0 |
| pCPU3 host timer IRQs | 24977 | 19024 | 0 |

`cntp-sysreg` is zero in every cell, proving that this Linux image does not
access CNTP even when it is exposed. `direct_overlaps` is also zero in every
cell, so the data does not support an old-active-PPI overlap as the main P99
cause.

Changing only the timer contract (`cntp-trap -> cntv-trap`) improved timerlat
IRQ P99 by 11.46% and thread P99 by 1.70%, while cyclictest P99 worsened by
9.19%. Therefore the cyclictest movement is not evidence that the AxVisor
timer injection path regressed; the Guest-visible IRQ and thread stages moved
in the opposite direction.

Changing only WFI handling (`cntv-trap -> cntv-passthrough`) removed the WFI
exits, software vtimer arm/callback path, and pCPU3 host timer IRQs. It improved
timerlat IRQ P99 by 13.22%, thread P99 by 10.37%, and cyclictest P99 by 5.76%.
However cyclictest P99.9 worsened by 19.32%, timerlat thread P99.9 worsened by
28.14%, and the roughly 307 ms cyclictest maximum did not move. The pilot thus
shows a plausible central-tail saving but fails the worst-tail acceptance
criterion.

The Zephyr control P99 also moved by 29.2% between the trapped and passthrough
cells even though its mechanism was unchanged. Together with the single
repeat, this prevents a performance claim from this pilot. Do not expand this
experiment to formal long runs until the higher-level Guest scheduling tail
and the unconditional post-VM-exit yield are isolated.

Reproduction:

```bash
RT_WFI_ISOLATION_DURATION_SEC=30 \
RT_WFI_ISOLATION_REPEATS=1 \
RT_WFI_ISOLATION_OUTPUT_ROOT=results/task1/linux-wfi-isolation/pilot-trace-v3-2026-08-17 \
scripts/test/rt-partition/run-linux-wfi-isolation.sh
```

The exact sequence and input paths are recorded in `protocol.txt`; per-cell
hashes and build commands are recorded under each `stress-dedicated` archive.
