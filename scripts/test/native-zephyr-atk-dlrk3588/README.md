# ATK-DLRK3588 native Zephyr baseline

This directory reproduces the physical Task 1 native baseline on RK3588. It
builds the existing 10 ms periodic probe as a Zephyr 4.4.2 non-secure BL33 and
wraps it in the exact Rockchip RAMBOOT format used by the accepted run.

The validated handoff is:

```text
Maskrom -> pinned RK3588 RAMBOOT loader
         -> Zephyr BL33 at 0x50000000
         -> upstream TF-A BL31 at 0x00040000
         -> EXECUTE_SDRAM 0xaa -> Zephyr at Non-secure EL1
```

It does not use vendor U-Boot or OP-TEE. The related board runner only fills
RAMBOOT loader slots; it does not erase, flash, update a partition table, or
write an eMMC partition.

## Pinned inputs

| Input | Identity |
|---|---|
| Zephyr | `dccb09599635bdff17633fa7e9dab014b91dce90` (v4.4.2) |
| Board target | `roc_rk3588_pc/rk3588` |
| Rockchip `loaderimage` | SHA256 `e26a311d449c6254d0d89ecaf8cd1870438205e07a66b27265d68830b8977439` |
| RAMBOOT loader v1.21.106 | SHA256 `77946243210318fea16ba4e04a22e7d18a5348cfd1328ef4accb3bb4bb5a7787` |
| TF-A BL31 trust image | SHA256 `754383b8bfb15f6e7ab7616a03bad8054cae7ca9701519bc7349b9cc9fb0c73d` |
| TF-A source | `6a164dda7208d3f2c0a5c4a1681db5ec37532bf5` (v2.15.0) |

Firmware and vendor tools are inputs, not repository artifacts. Obtain them
from a trusted Rockchip/TF-A workspace and check the hashes above. Do not
substitute a vendor BL31: that earlier chain left the timer interrupts in a
secure group and is not equivalent to the accepted run.

## Build

Use a dedicated Zephyr checkout because the build needs the included four-line
UART2 MMU patch:

```bash
scripts/test/native-zephyr-atk-dlrk3588/build.sh \
  --zephyr-base /path/to/zephyr \
  --loaderimage /path/to/rkbin/tools/loaderimage \
  --build-dir /path/to/build-native-periodic \
  --output-dir /path/to/native-output \
  --apply-zephyr-patch
```

The script rejects a different Zephyr commit or `loaderimage` binary. It also
checks that the products exactly reproduce the accepted identities:

```text
zephyr.bin
  5a22dec9b3b8f92f8b2ea9c5228c571236b2ae37b38300513d472622f212be4c
zephyr-native-periodic-bl33.img
  59ef4dd3ffab6a0d767755cc3822d67a5047cfa227c338e2312fa062ff01fd1d
```

## RAM-only board run

Capture `/dev/ttyACM0` at 1,500,000 baud with exactly one reader. Then run:

```bash
scripts/board/atk-dlrk3588-native-zephyr-ram-boot.sh \
  --loader /path/to/rk3588_ramboot_loader_v1.21.106.bin \
  --bl33 /path/to/native-output/zephyr-native-periodic-bl33.img \
  --trust /path/to/trust-native-bl31.img \
  --execute-tool /path/to/rkdeveloptool-1.3
```

The board runner pins both rkdeveloptool implementations and every firmware
input before sending anything. A physical reset or power cycle returns to the
vendor system stored on the board.

Passing output contains 300 CSV samples followed by:

```text
PERIODIC LATENCY COMPLETE samples=300
```

The accepted console log, parsed CSV, comparison table, and hashes are under
`results/atk-dlrk3588-native-zephyr-20260824/`.
