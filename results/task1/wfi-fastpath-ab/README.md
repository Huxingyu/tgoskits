# WFI/CNTV fast-path single-variable A/B

Date: 2026-08-16

This experiment keeps the guest images, pCPU placement, burner load, 90-second
guest duration, and result parser unchanged. The independent variable is the
dedicated Zephyr VM timer contract:

- pre: trap guest WFI and use the AxVM software timer/park/wake path;
- post: expose CNTV only and allow hardware WFI on the dedicated pCPU.

## Results

| Metric | Pre | Post | Change |
|---|---:|---:|---:|
| pCPU1 WFI exits in the Zephyr window | 1,952 | 0 | eliminated |
| pCPU1 timer exits in the Zephyr window | 1,907 | 1,996 | still one hardware wake IRQ per period |
| P99 jitter | 963,152 ns | 778,576 ns | 1.24x lower, 19.2% reduction |
| P99.9 jitter | 1,119,472 ns | 870,128 ns | 1.29x lower, 22.3% reduction |
| Maximum jitter | 1,119,472 ns | 870,128 ns | 22.3% reduction |
| Misses above the 1 ms tolerance | 3/300 | 0/300 | 3 to 0 |

The VM-exit result is the deterministic mechanism proof: the periodic WFI
instruction trap and host task park/wake path are absent after the change.
The remaining `timer` exits are expected. The counter is defined as the host
virtual-timer PPI exit, which is the hardware CNTV wakeup that transfers control
from the guest to EL2.

The latency change is a one-run observation and is not yet a statistical claim.
Repeated interleaved runs are required before reporting the 1.24x/1.29x values
as a stable performance improvement.

Evidence:

- `pre/stress-dedicated/zephyr-stats.txt`
- `pre/stress-dedicated/vmexit-before.txt`
- `pre/stress-dedicated/vmexit-zephyr-after.txt`
- `post/stress-dedicated/zephyr-stats.txt`
- `post/stress-dedicated/vmexit-before.txt`
- `post/stress-dedicated/vmexit-zephyr-after.txt`
