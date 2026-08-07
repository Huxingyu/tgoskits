# OpenRace 2026 Day5 进度

日期：2026-08-07

## 完成判据

- `MAP_ALLOC` Linux Guest 有真实内核输出，而不是只记录 `VM[1] boot success`。
- Linux 通过 `/psci` 完成 2-vCPU 启动，输出 `SMP: Total of 2 processors activated`。
- Linux stress init、Zephyr 周期采样器和 DMA quarantine 结果在同一双 Guest 运行中可观察。
- 启动参数从 Axvisor 配置正确进入 AArch64 guest FDT 的 `/chosen/bootargs`。

## 根因与修复

`create_guest_fdt` 生成的 FDT 在运行时会创建 `/chosen`，但原实现只保留已有 FDT 的
`bootargs`，没有复制 `AxVMCrateConfig.kernel.cmdline`。因此 `earlycon`、`rdinit` 和
stress init 参数没有进入 Linux；Guest 实际可以执行，但没有可观察控制台或 workload
标记。

修复 `virtualization/axvm/src/boot/fdt/core/tree.rs` 和 `core/create.rs`，让显式配置的
`kernel.cmdline` 覆盖已有 `bootargs`；没有显式配置时继续沿用原有 bootargs 清理规则。
新增回归测试 `runtime_patch_copies_configured_kernel_cmdline_into_chosen`。

旧实现验证：该测试因 `/chosen/bootargs` 缺失而失败。修复后：

```text
test ...runtime_patch_copies_configured_kernel_cmdline_into_chosen ... ok
```

验证结果：`cargo test -p axvm --lib` 共 156 个测试通过；`target/debug/tg-xtask clippy
--package axvm` 的 base、`fs`、`host-fs`、`host-test`、`sstc` 和 `tls` 六组检查全部通过；
`cargo fmt --all -- --check` 通过。

## 运行证据

构建与运行命令（使用本地 Debug 构建配置）：

```text
target/debug/tg-xtask axvisor qemu \
  --config os/axvisor/tmp/day5-qemu-aarch64-debug.toml \
  --qemu-config os/axvisor/configs/qemu/qemu-aarch64.toml \
  --vmconfigs os/axvisor/tmp/vmconfigs/day3-linux-initramfs-aarch64.toml \
  --rootfs tmp/axbuild/rootfs/rootfs-aarch64-alpine.img/rootfs-aarch64-alpine.img
```

单 Linux `MAP_ALLOC` 日志：

- `Booting Linux on physical CPU ...`
- `earlycon: pl11 at MMIO32 0x09000000`
- `Kernel command line: earlycon=... console=ttyAMA0 ... rdinit=/bin/sh`
- 加入 `/psci` 直通后：`SMP: Total of 2 processors activated`
- `Run /bin/sh as init process`

双 Guest stress 命令：

```text
target/debug/tg-xtask axvisor qemu \
  --config os/axvisor/configs/board/qemu-aarch64.toml \
  --qemu-config os/axvisor/configs/qemu/qemu-aarch64.toml \
  --vmconfigs os/axvisor/tmp/vmconfigs/day4-linux-stress-aarch64.toml \
  --vmconfigs os/axvisor/tmp/vmconfigs/day4-zephyr-periodic-aarch64.toml \
  --rootfs tmp/axbuild/rootfs/rootfs-aarch64-alpine.img/rootfs-aarch64-alpine.img
```

原始日志已归档为 `results/day5/axvisor-dual-stress.log`（原始路径：
`/tmp/day5-dual-stress-fixed.log`）。同一运行中观察到：

```text
VM[1] boot success
VM[2] boot success
Booting Linux on physical CPU 0x1
SMP: Total of 2 processors activated.
LINUX STRESS START workers=2
PERIODIC LATENCY COMPLETE samples=300
```

日志没有 `DMA coherent allocation ... quarantined`；`results/day5/README.md`
中的 `rg` 命令会把该条件作为机器可读断言执行。

## Day5 最小改造与回归

根据同场基线中 Zephyr 直通 `/timer`、独占 pCPU 3 且 Linux stress 未显著放大尾延迟的结果，未把软件 vIRQ 队列或 timer wheel 当作主改造对象，而是冻结 AArch64 vCPU lower-EL host-IRQ 边界。

原实现的事务边界是：`gic::fetch_irq()` 已调用 ArceOS `ax_hal::irq::handle_irq(0)`，完成当前 GIC IRQ 的 claim、dispatch 和 EOI；退出 deferred 阶段又调用通用 `after_external_interrupt()`，导致同一 host IRQ 被再次 dispatch。该重复调用可能把已处理 IRQ 重新视为 spurious，并在 Guest 返回路径增加不必要的尾延迟。

已在 `virtualization/axvm/src/arch/aarch64/mod.rs` 和 `virtualization/axvm/src/architecture/ops.rs` 完成最小改造：AArch64 lower-EL IRQ 的 deferred 阶段不再重复 host dispatch，只保留 `check_timer_events()`。新增确定性回归 `already_handled_host_irq_is_not_dispatched_again`，通过真实 deferred 边界 helper 和计数闭包断言 dispatch 次数为 0、timer 检查次数为 1；旧实现会在该回归中再次 dispatch。

验证：`cargo check -p axvm --target aarch64-unknown-none-softfloat` 通过；`cargo test -p axvm --lib --features host-test` 175 个测试通过，其中包含上述回归；`cargo clippy -p axvm --lib --no-default-features -- -D warnings` 通过。按仓库要求运行的 `cargo xtask clippy --package axvm` 受环境缺少 `libudev.pc` 阻塞，未把该失败误报为代码问题。

该改造尚无 idle/stress A/B 数据，不能据此声称实时指标改善；下一步必须在相同镜像、pCPU 绑定、设备配置和采样口径下重跑，并观察 spurious IRQ、p99.9、max 和 deadline miss。

## 仍未完成

- 已以原始日志为来源生成 Linux idle/stress 的 300 样本 CSV；交织字节中的四条记录按采样器不变量唯一恢复，过程和哈希见 `results/day5/README.md`。
- 基线显示 AxVisor 双 Guest 的尾延迟高于 Native QEMU，但 stress 没有比 idle 更差：idle p99.9/max 为 1.344224 ms，stress 为 869.792 µs；由于 Zephyr 使用直通 `/timer` 并独占 pCPU 3，这只能把审计范围缩小到 AArch64 vCPU entry/host-IRQ 边界，不能直接冻结软件 vIRQ 队列或 timer wheel 改造。
- 新增本地 `interrupt_mode = "emulated"`、Zephyr 绑定 pCPU 3 的探针后，VM 创建和 vCPU 启动成功，但从约 `0.903854s` 起持续收到 `IrqId { domain: 7, hwirq: 27 }`，未产生周期采样。该 IRQ 是 Guest virtual-timer PPI 27；当前 `arm_vgic` 的软件 timer 主要覆盖 CNTP/PPI 30，不能把 PPI 27 直接当宿主 IRQ dispatch。一次临时“注册宿主 handler 后排队 IRQ 27”的验证会造成约 100 µs 重复 level IRQ，Guest 只打印 Zephyr banner，因此已回退，不作为修复。
- 当前 emulated PPI27 候选仍未修复：需要明确 Guest virtual timer 的硬件 level/EOI 处理，或让 Guest 使用已有 CNTP 软件定时器路径；它不阻塞当前 `passthrough` 主线。
- lower-EL host-IRQ 最小改造尚未完成 A/B 和长稳测试，不能替代 Day6 的改造前后数据。
- 网络协议、AI 闭环和最终提交材料尚未开始，不以本日启动证据替代这些门槛。

## Day5 CSV 统计

统计命令：

```bash
python3 scripts/test/rt_latency_stats.py results/day5/axvisor-dual-idle.csv
python3 scripts/test/rt_latency_stats.py results/day5/axvisor-dual-stress.csv
```

| 场景 | 样本 | mean jitter | p99 | p99.9 / max | deadline misses |
| --- | ---: | ---: | ---: | ---: | ---: |
| AxVisor dual idle | 300 | 253.909 µs | 349.872 µs | 1.344224 ms | 300 |
| AxVisor dual Linux stress | 300 | 197.215 µs | 316.304 µs | 869.792 µs | 300 |

两组最大值都出现在 sequence 0 启动阶段；这说明当前数据足以把重点放在 AArch64 vCPU entry/host-IRQ 观测和启动后尾延迟上，但不能声称 Linux stress 已经造成调度竞争。严格 deadline miss 口径与 Day4 相同，详见 `results/day5/README.md`。
