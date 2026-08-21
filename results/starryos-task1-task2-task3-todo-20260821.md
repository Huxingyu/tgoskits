# StarryOS Task1/Task2/Task3 completion TODO

Date: 2026-08-21
Branch: `openrace/starryos-task2-task3`
Worktree: `/home/huhu/tgoskits-starry`

## Scope and completion rule

This checklist closes the remaining StarryOS evidence gaps without changing the
T2N1 wire protocol or modifying the independent YOLO worktree at
`/home/huhu/tgoskits-rt`. The final Task3 workload is real ncnn/YOLO inference
inside the StarryOS Guest. The completed pure-Rust CNN path remains preliminary
bring-up evidence, not the final model workload.

A row is complete only when the current source revision has the required Guest
logs, dual-ended packet capture where applicable, verifier output, exact run
steps, and SHA256 provenance. Unit tests and host-only responders are supporting
evidence, not substitutes for a real StarryOS + Zephyr run.

Full physical MSI-X/LPI passthrough is not part of this checklist. The current
QEMU-virt NVMe endpoint uses the documented `msix_qsize=1` legacy-INTx fallback;
implementing generic MSI-X passthrough would be a separate high-risk platform
feature requiring its own design and review.

## Execution tracker

Final evidence root: `results/starryos-task123-final-20260822/`.

Diagnostic validation completed on 2026-08-22:

- Task2/Task3 six-scenario PASS archives:
  `results/starryos-yolo-diagnostic-20260822/{normal-005,drop-ack-001,out-of-order-001,invalid-parameter-001,blackout-004,model-rejected-003}`.
- Every archive above contains matching StarryOS/Zephyr packet ledgers,
  `verify-pcap.log: PASS`, `verify-scenario.log: PASS`, exact commands, Guest
  logs, rootfs artifact hashes and `SHA256SUMS.txt`.
- Task1 diagnostic archives under
  `results/starryos-task1-diagnostic-20260822/` used the preliminary CNN and
  therefore do not satisfy the final ncnn/YOLO Task1 requirement.

- [x] Commit and push the Task1 A/B runner/config/verifier implementation so all
      evidence runners start from a clean tracked worktree.
      Implementation commit: `eb6f92da7`; pushed to
      `origin/openrace/starryos-task2-task3` before final evidence collection.
- [x] Run the identical persistent ncnn/YOLO/T2N1 workload under RR and bounded
      FP-RR:

  ```bash
  scripts/test/net-dual-guest/run-starry-task1-ab.sh \
    results/starryos-task123-final-20260822/task1
  ```

  Evidence: `results/starryos-task123-final-20260822/task1/`. Both arms completed
  three CONTROL/STATUS cycles with matching Guest/model hashes and passing
  dual-pcap verification. RR RTT min/median/p95/max was 133/448/590/590 ms;
  FP-RR was 146/479/597/597 ms and reported
  `lower_priority_services=189`.

- [x] Run all six Task2/Task3 scenarios from the same source revision:

  ```bash
  for scenario in normal drop-ack out-of-order invalid-parameter blackout model-rejected; do
    scripts/test/net-dual-guest/run-starry-task23-scenario.sh \
      "$scenario" "results/starryos-task123-final-20260822/task23/$scenario"
  done
  ```

  Evidence: `results/starryos-task123-final-20260822/task23/`. `normal`,
  `drop-ack`, `out-of-order`, `invalid-parameter`, `blackout`, and
  `model-rejected` each contain passing pcap/scenario verifier logs, exact
  commands, Guest logs, artifact hashes and `SHA256SUMS.txt`. The preserved
  `normal-startup-failure-001` directory records an initial pre-Guest
  AxVisor/QEMU startup failure and is not counted as a passing scenario.

- [ ] Generate the StarryOS-versus-Linux ncnn/YOLO comparison from retained
      real-Guest logs. Both sides must use matching ncnn revisions, model/input
      hashes, preprocessing, thresholds, single-thread configuration and T2N1
      control mapping. Fixture replay is not admissible as in-Guest inference.
- [ ] Run the regression commands in the final delivery gate, save their output
      under the final evidence root, and require every command to return zero.
- [ ] Audit every checkbox against a concrete file, update `FINAL-REPORT.md`,
      create a top-level SHA256 manifest, commit, and push the delivery.

Task1 acceptance is intentionally narrow: the two retained host configs may
differ only by `rr-scheduler` versus `fp-rr-scheduler`; both Guest configs,
images and workload hashes must match; both arms need at least three
CONTROL/STATUS cycles and an `rt stat` snapshot; the FP-RR arm must report a
nonzero `lower_priority_services` counter. No scheduler source change is part
of this execution tracker.

## Task2: StarryOS and Zephyr protocol completion

- [x] Normal StarryOS `CONTROL` -> Zephyr `ACK` + `STATUS` path.
- [x] Keep the StarryOS endpoint alive after its first successful exchange.
- [ ] Make `RetryExhausted` enter observable Safe state without terminating the
      Guest application. The current dropped-ACK case recovers on retransmission
      and intentionally does not exhaust all retries.
- [x] Make `HeartbeatTimeout` enter observable Safe state without terminating
      the Guest application.
- [x] Recover from Safe on a valid same-session frame and resume CONTROL traffic.
- [x] Capture one dropped ACK followed by retransmission and duplicate handling.
- [x] Capture an out-of-order reliable frame followed by `ERROR` and Safe state.
- [x] Capture an invalid CONTROL payload followed by `ERROR` and Safe state.
- [x] Capture blackout -> Safe -> recovery -> resumed CONTROL.
- [x] For every fault case, retain StarryOS/Zephyr logs, injector markers,
      two Guest pcaps, verifier output, commands, and SHA256 hashes from the
      final clean source revision. Final evidence is under
      `results/starryos-task123-final-20260822/task23/` at Git ID `eb6f92da7`.

## Task3: real in-Guest ncnn/YOLO and safety completion

- [x] Preliminary smoke: run the frozen pure-Rust CNN forward pass inside the
      StarryOS Guest.
- [x] Preliminary smoke: send the CNN-derived output through T2N1 and receive
      Zephyr STATUS.
- [x] Reuse the Linux path's pinned ncnn revision and converted YOLO model without
      modifying or depending on files from the independent worktree at runtime.
- [x] Cross-build a static AArch64 musl ncnn runtime and StarryOS endpoint, and
      install the executable, `.param`, `.bin` and input asset in the StarryOS
      rootfs with SHA256 provenance.
- [x] Log `TASK3_MODEL_READY`, real `TASK3_INFER` duration and
      `TASK3_DETECTION` from ncnn/YOLO execution inside the StarryOS Guest.
- [x] Validate every detection through the existing bounded perception contract
      before constructing T2N1 CONTROL.
- [x] Send a YOLO-derived CONTROL through T2N1 and receive Zephyr ACK/STATUS in
      the same real dual-Guest run.
- [x] Expose a deterministic YOLO model-rejection test mode which enters
      observable Safe state without sending an unsafe CONTROL value.
- [x] Demonstrate post-blackout YOLO inference/control resumption in the same
      real dual-Guest run.
- [ ] Compare StarryOS ncnn/YOLO with real Linux Guest ncnn/YOLO using inference
      time and protocol/control-loop observations under clearly stated QEMU
      limitations. Do not use fixture replay or host inference as either side.

## Task1: reuse of the existing AxVisor real-time mechanisms

- [x] Freeze the scheduler implementation: no new policy or unbounded IRQ-tail
      mechanism is introduced for this bonus path.
- [x] Build the StarryOS + Zephyr topology with the existing RR baseline and
      bounded fixed-priority scheduler using identical Guest images and load.
- [x] Prove both Guests boot, remain live, and complete the same ncnn/YOLO Task2/
      Task3 control workload under each scheduler.
- [x] Collect scheduler counters and protocol timing observations for both runs.
- [x] Report the comparison as QEMU software-in-the-loop evidence, not a physical
      board WCET or a new Task1 performance claim.
- [x] Retain exact configs, logs, current-revision image hashes, and comparison
      summary.

## Final delivery gate

- [ ] Run `cargo test -p task2-net-protocol` and `cargo test -p task3-model`.
- [ ] Run the AArch64 ncnn smoke against the exact runtime/model/input assets
      installed in the StarryOS rootfs.
- [ ] Run the Starry endpoint's targeted tests and clippy checks.
- [ ] Run the Python dual-Guest regression suite.
- [x] Run the T2N1 and fault pcap verifiers over every retained Task1 and
      Task2/Task3 scenario.
- [x] Regenerate Task1 and six-scenario evidence from the clean implementation
      revision and record its Git ID (`eb6f92da7`).
- [ ] Update `FINAL-REPORT.md` to `complete` only if every mandatory row above is
      proven; otherwise retain `partial` and identify the exact missing evidence.
- [ ] Commit and push each independently verified stage to
      `origin/openrace/starryos-task2-task3`.
