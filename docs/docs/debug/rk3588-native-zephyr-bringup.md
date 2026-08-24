# RK3588 native Zephyr bring-up on ATK-DLRK3588

This note preserves the reusable findings from the 2026-08-24 physical-board
bring-up. It intentionally excludes probe binaries, vendor trees, build
directories, and failed-run logs. Those remain in the external exploration
archive; the repository keeps only the final workflow and accepted evidence.

## Result and scope

Zephyr 4.4.2 at commit
`dccb09599635bdff17633fa7e9dab014b91dce90` boots directly as the non-secure
BL33 on ATK-DLRK3588. The accepted run reaches `POST_KERNEL`, completes 300
absolute-deadline 10 ms samples, and proves the ARM generic timer interrupt,
scheduler block/wake path, UART2 console, MMU, and GICv3 are operational.

This is a native RTOS timing baseline. It does not run AxVisor, StarryOS, a
second Guest, networking, or YOLO, and therefore must not be presented as a
replacement for the integrated Task 1-3 experiment.

## Final handoff contract

```text
RK3588 Maskrom
  -> RAMBOOT loader v1.21.106
  -> BL33 loaderimage at 0x50000000
  -> upstream TF-A BL31 at 0x00040000
  -> ExecuteSDRAM opcode 0x19 / subcode 0xaa
  -> Zephyr in Non-secure EL1
```

The accepted BL31 is upstream TF-A commit
`6a164dda7208d3f2c0a5c4a1681db5ec37532bf5` and prints
`v2.15.0(release):6a164dd`. It is packed in a Rockchip trust image without BL32
or OP-TEE. BL33 is generated with Rockchip `loaderimage --pack --uboot`, load
address `0x50000000`, and a 2 MiB output slot.

The board-side sequence is implemented by
`scripts/board/atk-dlrk3588-native-zephyr-ram-boot.sh`. The two commands named
`write` target the pinned RAMBOOT loader's volatile slots:

| Slot | Payload | Runtime address |
|---|---|---:|
| `0x2000` | loaderimage-wrapped Zephyr BL33 | `0x50000000` |
| `0x4000` | trust image containing BL31 | `0x00040000` |

They are not eMMC LBAs under this pinned loader. The workflow must never add
`upgrade-loader`, erase, flash, partition-table, or partition-write commands.
A reset or power cycle returns to the vendor system.

## Why the earlier paths failed

### A virtual Guest binary is not a native baseline

The existing RT-Thread and Zephyr Guest images describe virtual RAM, UART, GIC,
and entry addresses. Loading either directly on RK3588 would test an invalid
machine contract, not RTOS latency. The native result instead uses Zephyr's
`roc_rk3588_pc/rk3588` board support and a board-specific firmware handoff.

### UART2 disappeared after enabling the MMU

The pinned Zephyr RK3588 MMU table mapped the GIC but omitted the board's UART2
console at `0xfeb50000`. Early raw output could work and then disappear across
the MMU transition. The final workflow applies the four-line UART2 device
mapping in
`scripts/test/native-zephyr-atk-dlrk3588/patches/0001-rk3588-map-uart2.patch`.

### Vendor U-Boot/firmware retained secure interrupt ownership

Under the vendor U-Boot/BL31/OP-TEE chain, Zephyr reached its timer setup but
did not receive scheduler ticks. GIC snapshots and focused probes showed ARM
generic timer PPIs 27/30 and Rockchip timer SPI 321 remaining Secure Group 0.
Changing Zephyr sleep code or treating the stall as a scheduler bug did not
address that firmware ownership boundary.

Direct handoff through upstream TF-A BL31 removed the secure grouping blocker.
`CONFIG_ARMV8_A_NS=y` makes the intended non-secure execution mode explicit,
and `CONFIG_GIC_SAFE_CONFIG=y` avoids relying on destructive inherited GIC
state while Zephyr establishes its runtime configuration.

## Reproduction discipline

Use the repository build and board scripts rather than replaying exploratory
commands. They enforce the Zephyr commit and exact SHA256 identities for the
Rockchip tools and firmware inputs. Keep one serial reader on `/dev/ttyACM0` at
1,500,000 baud; competing readers split bytes and can make a successful boot
look truncated.

The passing markers are ordered:

```text
ATK_NATIVE_PERIODIC_PREP
sequence,timestamp_ns,deadline_ns,actual_ns,jitter_ns
... 300 samples ...
PERIODIC LATENCY COMPLETE samples=300
```

For an independent timer acceptance run, the final marker is
`ATK_TIMER_ACCEPT_PASS`. A banner or early UART marker alone is not a native
timer/scheduler acceptance result.

## Evidence and interpretation boundary

The reviewable evidence is in
`results/atk-dlrk3588-native-zephyr-20260824/`. The accepted native run reports
P99 `2.041 us` and maximum `4.000 us` across 300 samples, with no sample above
1 ms or the 10 ms period.

The native-to-single-Guest gap includes the complete virtual timer, interrupt,
Host scheduling, and Guest runtime path; it is not a pure instruction-level
hypervisor microbenchmark. Contention claims should use the identical-Guest
single-versus-dual-Guest controls, while RR-versus-FP-RR claims should use the
same workload and Guest build on both scheduler arms.

## External archive

The complete local exploration archive at the time of closure was:

```text
/home/huhu/atk-bringup/native-zephyr-atk-dlrk3588-20260824
```

It contains GIC scans, timer probes, vendor sources, firmware tools, build
trees, failed logs, and final binaries. Its location is historical metadata,
not an input hard-coded by the repository workflow. Preserve or move that
archive to external storage; do not commit its generated contents.
