# Final evidence manifest (2026-08-21)

This is the human-readable index for the current delivery branch. Hashes are
SHA-256 of the files at `openrace/task1-rt-partition` HEAD
`ea935ff3d` and are included to prevent an old run being silently substituted
for the current evidence.

## Canonical design and score documents

| Artifact | SHA-256 |
|---|---|
| `results/task1/README.md` | `84e13805af4df1ca14f4cafd03b1b2dc61411099b7bc590de20ea7d5f4962a24` |
| `results/task1/two-gap-closure-20260820.md` | `51f2ee2f057ec5f2708dfe2e6c2528e049373479646052c26b919e32011a0440` |
| `results/task1/irq-tail-preemption-design.md` | `cac0440a2a4d25c3907a6063991fb4fdc82929b4f2db55ba5f45714322c02195` |
| `results/final-execution-todo-20260821.md` | `9ea350e755e3c18a5a39b039d16a5b7c5b4a6de0016a1de342b167021e608bcf` |
| `results/final-submission-scorecard-20260821.md` | `839ad11a00f5e94dff8ab0357b58b5b94875c0ab61983fc80d43617b15b405ff` |
| `results/task2-final-run-20260821.md` | `2d8046ab9456c3b21cb2b1c288fe94415b04b87b08829ee10c3f7336e7f96a5a` |
| `book/design/task2-dual-guest-network-final.md` | `4cd228e46fc1aeb3e8e3cd98b0429cc2ab95e33318c886e8ae71d97c34d489fe` |
| `book/design/task3-ai-design.md` | `2db4bc5271e62bc494b49a973c9c6a0c3328b5ba4b6e8ee1ce9d5e84929b69c8` |
| `results/task3/README.md` | `dfa04f2ab5db0664f40b6b7419ca04a5d56e72a61fac895ebd101ef25d265cbc` |
| `results/bonus-path-audit-20260821.md` | `3a42efcd6eba2014535b1fd9227fc7ba14805f2236d134d929bcb6a70c1cb149` |
| `results/demo-runbook-20260821.md` | `39fc866b66923d50ba117b7077987ab517694a454584da0b03cdde40135386b2` |

## Current HEAD Task3 evidence

| Run | Evidence directory | Required verifier |
|---|---|---|
| Normal YOLO | `results/task3/switch/current-head-yolo-capture/` | `verify_pcap.py --require-task2` |
| YOLO blackout/recovery | `results/task3/switch/fault-current-head-yolo-fault-validated/` | marker order + `verify_pcap.py --require-task2` |
| YOLO ACK drop | `results/task3/fault-current-head-yolo-ack-drop-v2/` | `verify_fault_pcap.py` |
| YOLO out-of-order | `results/task3/fault-current-head-yolo-injection-out-of-order/` | `verify_protocol_injection.py --mode out-of-order` |
| YOLO invalid parameter | `results/task3/fault-current-head-yolo-injection-invalid-parameter-v2/` | `verify_protocol_injection.py --mode invalid-parameter` |

All five directories contain the run/build or guest/proxy logs, pcaps where
applicable, and a manifest with input/output hashes. The two protocol-injection
runs were executed on the QEMU wire and passed their dedicated verifier.

## Reproduction gates

```bash
cargo test -p task2-net-protocol
python3 -m unittest discover -s scripts/test/net-dual-guest -p 'test_*.py'
bash -n scripts/task3/run-task3-fault.sh
python3 -m py_compile scripts/test/net-dual-guest/verify_protocol_injection.py
git diff --check -- book/design results scripts/task3 scripts/test/net-dual-guest
```

The full dual-Guest QEMU runs are intentionally explicit rather than silently
treated as a host-only unit test. QEMU SIL measurements are not physical-board
WCET claims, and `embedded:fixture-replay` is not an ONNX-runtime benchmark.

## Delivery limitations

- StarryOS/STERRORS and a second RTOS/board remain separately audited in
  `results/bonus-path-audit-20260821.md`; no bonus is claimed without a matching
  observable protocol/control loop.
- `origin/dev` has conflicts with this long-lived evidence branch; integration
  must be performed in a review branch, not by silently rewriting this evidence
  branch.
