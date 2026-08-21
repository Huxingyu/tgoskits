# Task3 YOLO current-HEAD validation (2026-08-21)

This record separates the checks that completed on commit `0d8789a81` from the
full dual-Guest QEMU run that could not start because a required Zephyr image
was absent. It must not be cited as current-HEAD QEMU runtime evidence.

## Completed checks

The hardware-independent Task2/Task3 contract gate passed:

```bash
bash scripts/test/net-dual-guest/run-ci-regression.sh
```

Observed results:

- `task2-net-protocol`: 21 passed;
- Python network tooling: 14 passed;
- CNN controller compile check: passed;
- YOLO controller compile check with
  `TASK3_MODEL_PATH=embedded:fixture-replay`: passed;
- final marker: `TASK2_CI_GATE_PASS`.

The pinned YOLO11n fixture also reproduced the checked-in decision contract:

```bash
python3 scripts/task3/run_yolo_fixture.py \
  --model tmp/task3-yolo/yolo11n.onnx \
  --out-dir /tmp/task3-yolo-current-head
```

The model SHA-256 was
`634279b40c07c6391472c51ad45b81ebc48706a9a1fe72dd3396322acd0c053b`.
The three fixture outcomes were no detection, target `419`, and a step-limited
target `600`, matching `yolo-fixture-manifest.json`.

The current HEAD Linux endpoints were rebuilt with:

```bash
TASK3_CONTROL_LOOP=1 \
TASK3_MODEL=yolo \
TASK3_MODEL_PATH=embedded:fixture-replay \
scripts/test/net-dual-guest/build-linux-task2.sh
```

The controller, managed endpoint, input artifacts, and generated initramfs
hashes are recorded in `current-head-build-manifest.toml`.

## Full QEMU attempt

The following current-HEAD run was attempted after installing the YOLO
controller initramfs into the expected switch-run location:

```bash
MIN_ELAPSED_MS=12000 \
  bash scripts/task3/run-task3-switch.sh current-head-yolo ai
```

Axvisor stopped during its build-script input validation:

```text
Error: Path /home/huhu/tgoskits-rt/tmp/net-dual-guest/zephyr-task2/zephyr-task2.bin not found
```

No Guest booted, so this attempt proves neither UDP exchange nor YOLO
Safe/recovery behavior. The local cached Zephyr source is an incomplete dirty
recovery checkout, and no usable Zephyr SDK toolchain is installed. Reusing an
unversioned binary was rejected because it would not prove the current source.

## Resume command

After restoring a versioned Zephyr source tree and SDK, rebuild the switch-slot
image and rerun the same experiment:

```bash
ZEPHYR_BASE=<zephyr-source> \
ZEPHYR_SDK_INSTALL_DIR=<zephyr-sdk> \
TASK2_ZEPHYR_VIRTIO_SLOT=0 \
  scripts/test/net-dual-guest/build-zephyr-task2.sh

MIN_ELAPSED_MS=12000 \
  bash scripts/task3/run-task3-switch.sh current-head-yolo ai
```

Acceptance requires `TASK3_MODEL_READY`, at least one accepted
`TASK3_DETECTION`, `TASK3_CONTROL_SENT`, matching `TASK2_STATUS_RECEIVED`, two
verifiable pcaps, and a normal QMP exit. A separate blackout run is still
required to claim YOLO-mode Safe to Active recovery.
