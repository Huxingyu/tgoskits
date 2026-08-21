# StarryOS Task 1/2/3 follow-up issues

Date: 2026-08-22
Baseline delivery: `6f3098babc6746c2a2345864dbd91753b6b7e985`

## Resolved in this follow-up

- [x] Linux Guest YOLO inference blocked the T2N1 polling loop for 16-28
      seconds. Move only the Linux ncnn call to a background worker while the
      main loop continues ACK, STATUS, heartbeat and retransmission handling.
- [x] `task3-ncnn::infer` failed the broader `-D warnings` clippy gate because
      its public unsafe contract lacked a `# Safety` section.
- [x] The YOLO switch runner armed packet capture after the first CONTROL and
      could omit the first successful transaction. Arm capture after
      `TASK3_MODEL_READY`, before the first long inference completes.

## Validation target

- Real Linux Guest ncnn/YOLO remains identical to the StarryOS workload.
- At least two CONTROL/ACK/STATUS loops complete.
- Both pcaps contain the first transaction and pass the T2N1 verifier.
- No controller `RetryExhausted` or `OutOfOrder` event occurs.
- Protocol RTT is measured independently from the long ncnn inference time.

## Diagnostic result

The dirty-worktree diagnostic met the validation target and justified the
implementation fix, but it is not final revision-stamped evidence:

- Two real Linux Guest ncnn/YOLO inferences completed in 17,906,851 us and
  17,827,041 us, with the same class-75 detection and target 421.
- Their CONTROL-to-STATUS RTTs were 213 ms and 86 ms; heartbeats continued
  while both inference calls were running.
- Both Linux and Zephyr pcaps passed the T2N1 verifier. Each contains two
  CONTROL frames, four ACK frames, two STATUS frames and 16 HEARTBEAT frames.
- Neither console nor pcap contains an ERROR, `RetryExhausted`, or
  `OutOfOrder` event.

A clean-revision rebuild and rerun was subsequently completed at
`d2efbb7a6d4968ffee462d5e8cd5d1258ecc2029`:

- Two inference calls completed in 17,357,824 us and 17,681,608 us.
- Their CONTROL-to-STATUS RTTs were 365 ms and 84 ms.
- Both revision-stamped pcaps passed with the same 2 CONTROL, 4 ACK, 2 STATUS
  and 16 HEARTBEAT ledger and no protocol error.
- The clean evidence is archived under
  `results/starryos-task123-followup-d2efbb7a6-20260822/`.

## Remaining experimental limitation

- Task 1 proves RR and bounded FP-RR liveness plus observed QEMU timing. It
  does not prove universal acceleration. A physical-board run with a frozen
  load, enough repetitions and a declared latency objective is required for a
  performance or WCET claim; no scheduler redesign is justified by the current
  evidence alone.
