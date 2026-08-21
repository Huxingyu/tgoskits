# StarryOS + RT-Thread Task-2/Task-3 virtual evidence (2026-08-22)

RT-Thread endpoint commit:
`6ea682795bdbac59d3700b21e159ccaa3f7632cb`, BSP
`qemu-virt64-aarch64`, lwIP 2.0.3, toolchain
`aarch64-none-elf-gcc 10.2.1`. The T2N1 wire format and endpoint state
machine mirror the Zephyr endpoint; only the socket/clock/logging APIs are
RT-Thread-specific.

All four scenarios passed the pcap and scenario verifiers (`PASS` in each
`verify-pcap.log` / `verify-scenario.log`):

| Scenario | Result |
| --- | --- |
| normal | 3 control/status rounds with ACK/STATUS, `STARRY_T2N1_PASS` |
| drop-ack | seq=1 ACK dropped once, retransmit attempt=1, duplicate ACK recovered |
| retry-exhausted | ACK always dropped, attempts 1..5, `RetryExhausted` Safe, recovered |
| blackout | switch blackout, both sides Safe, recovery after `virtnet drop off` |

Key timestamps from the guest logs:

- blackout: `STARRY_T2N1_SAFE elapsed_ms=6153`, recovered at 11602 ms,
  `FAULT_RECOVERY_COMPLETE elapsed_ms=38647`.
- retry-exhausted: `RETRY_EXHAUSTED elapsed_ms=3027`, recovered at 3158 ms.

Per-scenario image hashes:

| Variant | SHA-256 |
| --- | --- |
| none (normal/blackout) | `14363b8ce6ede9ef19ad76d8d2aeca3ab9084cbde616b1cdf74609bca570b548` |
| drop-ack-once | `91c71e35ca42e8cdf86144175dbec35ff81e620eddaee1763d7020dabc99e567` |
| drop-ack-always | `184d47bf425d70caa4b26a9a717ea83f7bbe2b1aa95ad7848f761a22a641564e` |

Each scenario directory contains `run.log`, `steps.txt`, both pcaps, the
RT-Thread manifest, and the verifier output. Physical-board validation is a
separate follow-up and is not claimed by this virtual evidence.

## Task 1 with RT-Thread companion (status: not passing)

The shared-pCPU1 Task 1 scheduler A/B with RT-Thread as the companion Guest
is **not** claimed. Under the RR arm, StarryOS's ncnn inference either returns
`RuntimeError code -7` or completes with `NoDetection`; a log-reduced
RT-Thread image did not resolve it. This is a real integration issue that
remains open.

After the shared test-harness changes, the Zephyr Task 1 A/B was re-run and
passes (RR and FP-RR; FP-RR `lower_priority_services=194`). Evidence is in
`results/starryos-task1-zephyr-regression-20260822/`.
