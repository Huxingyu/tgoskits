# Day6 lower-EL IRQ 改造后探针

本次运行使用与 Day5 相同的双 Guest `passthrough` stress 配置，并从当前工作树重新构建 Axvisor：

```bash
target/debug/tg-xtask axvisor qemu \
  --config os/axvisor/configs/board/qemu-aarch64.toml \
  --qemu-config os/axvisor/configs/qemu/qemu-aarch64.toml \
  --vmconfigs os/axvisor/tmp/vmconfigs/day4-linux-stress-aarch64.toml \
  --vmconfigs os/axvisor/tmp/vmconfigs/day4-zephyr-periodic-aarch64.toml \
  --rootfs tmp/axbuild/rootfs/rootfs-aarch64-alpine.img/rootfs-aarch64-alpine.img
```

改造后二进制在同一运行中观察到 Linux 2-vCPU 启动、`SMP: Total of 2 processors activated`、
`LINUX STRESS START workers=2`、Zephyr `PERIODIC LATENCY COMPLETE samples=300`，日志未出现 DMA quarantine 告警。

原始输出保存为 `axvisor-dual-stress.log`。由于 Linux 内核日志与 Zephyr CSV 共用串口，直接抽取的 CSV
只包含 294 行，缺少 sequence `0, 2, 13, 14, 29, 39`；`axvisor-dual-stress.csv` 只作为重建工作副本，
不用于正式 A/B 结论。必须先按 Day5 README 中的采样器不变量恢复缺失行，再比较 p99、p99.9、max 和 deadline miss。

当前 294 行的非正式统计为：mean `165037.88 ns`、p99 `299808 ns`、p99.9/max `533712 ns`。
