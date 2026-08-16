# Task1 Formal Matrix Status

The formal comparison uses the same cyclictest guest duration in all four
scenarios. QEMU AArch64 TCG guest time can advance much more slowly than host
wall time under stress, so fixed loop count is retained only for short smoke
tests.

## Attempts

| Scenario / mode | Result | Evidence status |
|---|---|---|
| `idle`, 1,800,000 loops | completed in 1,932,320 ms wall time | retained in `legacy-idle-loop/`; not part of the uniform duration matrix |
| `stress-noiso`, 1,800,000 loops | timed out at 2040 s | first attempt was overwritten before archival |
| `stress-noiso`, 1,800,000 loops, TCG scale 2 | timed out at 3900 s | retained in `failed-stress-noiso-loop/` |
| pre-gate `stress-rt` | Zephyr completion failed before the console fix/gate | retained in `failed-stress-rt-pre-gate/` |
| `stress-noiso`, 10 s duration smoke | 9349 samples; no guest-uptime markers yet | flow-only evidence in `tmp/rt-partition/duration-validation/` |
| gated `stress-noiso`, 20 s duration smoke | 16,333 samples, 20.80 s guest uptime | accepted in `tmp/rt-partition/final-smoke/` |
| gated `idle`, 20 s duration smoke, TCG scale 2 | 15,477 samples, 22.09 s guest uptime | accepted in `tmp/rt-partition/idle-scale2-smoke/` |
| `idle`, 1800 s duration, TCG scale 1 | Linux completion timed out at 2100 s | retained in `failed-idle-duration-scale1/` |
| `idle`, 1800 s duration, TCG scale 2 | Linux completion timed out at 3900 s | retained in `failed-idle-duration-scale2/` |
| `idle`, 1800 s duration, fresh 2026-08-15 run | progress stopped at guest uptime 659.70 s; watchdog fired after 300 s | retained in `formal-2026-08-15/idle/` |
| `stress-dedicated`, 20 s duration | 15,318 samples, 38.27 s guest uptime; pCPU1 host ticks stayed zero | accepted in `tmp/rt-partition/validation-results/stress-dedicated/` |
| `stress-rt`, 60 s duration | stalled at guest uptime 49.36 s; watchdog fired after 300 s without progress | retained as failed smoke in `tmp/rt-partition/validation-results/stress-rt/` |
| `idle`, 120 s calibration | 120.15 s guest progress; recommended scale 2 | accepted in `results/task1/calibration/runs/idle/` |
| `stress-noiso`, 120 s calibration | 110.73 s progress markers; recommended scale 2 | accepted in `results/task1/calibration/runs/stress-noiso/` |
| `stress-dedicated`, 120 s calibration | stalled at 109.83 s before completion | failed calibration retained |
| `idle`, 1800 s duration, post-fix | 1,713,691 samples; 1792.17 s progress; Zephyr 300/300 | accepted in `formal-postfix-2026-08-16/idle/`; all hashes pass |
| `stress-noiso`, 1800 s duration, 30 s result drain | workload completed, but final CPU-stat drain exceeded runner timeout | retained in `formal-postfix-2026-08-16/stress-noiso-failed-result-drain-30s/`; runner failure, not OS stall |
| `stress-noiso`, 1800 s duration, 180 s result drain | 1,746,156 samples; 1794.90 s progress; Zephyr 300/300 | accepted in `formal-postfix-2026-08-16/stress-noiso/`; all hashes pass |
| `stress-dedicated`, 1800 s duration, post-fix | 1,727,468 samples; 1794.86 s progress; Zephyr 300/300; pCPU1 host ticks stayed zero | accepted in `formal-postfix-2026-08-16/stress-dedicated/`; all hashes pass |
| `stress-rt`, 1800 s duration, post-fix | 1,720,603 samples; 1795.09 s progress; Zephyr 300/300; pCPU1 host ticks stayed zero | accepted in `formal-postfix-2026-08-16/stress-rt/`; all hashes pass |

All long idle failures kept running guests without panic. The fresh run also
reproduces the stall without a dedicated pCPU, so it broadens the active
investigation to the common guest timer/host scheduler wake path. These runs
show that a
short duration smoke cannot predict long-run TCG guest-clock progress. The
runner now uses calibrated per-scenario scales where available and retains a
scale-3 fallback. After the `IRQ_ROUTES` fix, all four uniform formal scenarios
pass. The remaining runtime experiment is the one-hour `stress-rt` stability
run.

The first post-fix `stress-noiso` workload completed before the runner failed:
about 720 final `RT_CPUSTAT` lines exceeded the hard-coded 30-second wait for
`RT_INIT_DONE`. The runner now defaults `RT_RESULT_DRAIN_TIMEOUT_SEC` to 180
seconds and includes it in the outer timeout budget. The accepted rerun needed
about 39.36 seconds between `RT_CYCLICTEST_COMPLETE` and `RT_INIT_DONE`.

The historical idle `sha256sums` references mutable build inputs under
`tmp/` and `target/`; later rebuilding changed the initramfs and AxVisor binary,
so two entries no longer verify. The log, CSV, summary, configs, and vmexit
entries still verify. The runner now copies all build inputs into each result
directory and hashes only those archived copies. The old idle evidence is not
silently repaired with binaries from a later build.

## Formal Commands

```bash
RT_SCENARIO=idle RT_DURATION_SEC=1800 scripts/test/rt-partition/run-cyclictest.sh
RT_SCENARIO=stress-noiso RT_DURATION_SEC=1800 scripts/test/rt-partition/run-cyclictest.sh
RT_SCENARIO=stress-dedicated RT_DURATION_SEC=1800 scripts/test/rt-partition/run-cyclictest.sh
RT_SCENARIO=stress-rt RT_DURATION_SEC=1800 scripts/test/rt-partition/run-cyclictest.sh
```

The Linux guest kernel reports `Housekeeping: nohz unsupported. Build with
CONFIG_NO_HZ_FULL`. The matrix therefore measures the configured CPU affinity,
IRQ/load separation, and host RT partition; it does not claim guest
full-dynticks isolation.

The matrix Zephyr image waits for a UART start byte and resends it until the
START marker arrives. The runner releases it
after `RT_CYCLICTEST_START` and requires Zephyr completion before Linux
completion. Three VM-exit snapshots bound the Zephyr window and the full Linux
run separately.
