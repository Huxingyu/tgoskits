# Official dev + RR baseline status

## What was fixed

- Served the cached registry through a local HTTP endpoint, avoiding the
  upstream registry network dependency.
- Reused the existing AArch64 rootfs outside the official managed-image path.
- Added an official-only board profile selecting `sched-rr`.
- Removed modified-tree VM fields (`aarch64_virtual_timer_only`,
  `aarch64_wfi_policy`, and `inherit_host_devices`) from official VM templates.
- Staged the existing Linux RT initramfs in the official worktree.

## Result

The official `dev` source compiled successfully and AxVisor/QEMU started. Both
VM objects were created, but the Linux and Zephyr guests never reached the
measurement markers. The official runtime repeatedly emitted:

```text
Exception Class: 0x25
ESR_EL2: 0x96000047
```

and later `0x96000046` during guest boot. No `RT_CYCLICTEST_START`,
`PERIODIC LATENCY COMPLETE`, or accepted statistics were produced.

Therefore there is still no valid official-dev runtime percentage. The blocker
is now guest boot/runtime compatibility between the current RT initramfs/VM
assets and upstream `dev`, not the registry or scheduler build.

The attempted runs are retained under this directory; they must not be used as
performance samples.
