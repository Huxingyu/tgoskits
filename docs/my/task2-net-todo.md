# Task-2 网络探路执行 TODO（openrace/task2-net）

> 保存时间：2026-08-09
> 分支：`openrace/task2-net`，基于任务一 B 改造 `openrace/realtime-virq-ab @ 284a22bec`，
>   再叠加 `b5de2c0d4`（net-dual-guest 基线配置）。
> 机器状态：任务一 A/B 仍在运行，QEMU 类步骤等机器空闲后执行。

## 基线口径

- 本分支基于任务一 B 改造状态创建，包含 per-vCPU vIRQ dispatcher、GICR 修复、
  VM 启动 barrier 等 B 侧代码。
- 网络数据面不依赖任务一 B 的性能结论，只依赖同一套双 Guest / 设备隔离 / GICR
  修复底座。
- 三个 worktree：`tgoskits-origin` = 任务一 A 基线；`tgoskits-realtime` =
  任务一 B；`tgoskits-net` = 任务二（当前目录）。

## 评审来源

- Claude Code 独立复核（2026-08-09）。
- 复核结论存档：
  `/home/huhu/Library/Application Support/AI Expert Reviews/claude-20260809-190716.pRmjUe/reply.txt`

## 路线决策（评审后修正）

- Linux 侧优先 `map_type` 0→2（`MAP_RESERVED` @ `0x8000_0000`）原地恒等，
  绕开 aarch64 ramdisk 迁移缺口。
- RTOS 侧先试 ArceOS dyn + `MAP_IDENTICAL`；失败再退回“重链接 + `MAP_RESERVED`”。
- 中断路径优先 emulated GIC；passthrough 只做限时结论实验。
- 使用独立 `qemu-aarch64-net.toml`，不碰任务一 A/B 配置。
- 镜像必须搬进本仓库并记录 sha256，去掉跨工作树绝对路径。

## T0 准备（已完成；QEMU 相关验证留给 T1/T2）

- [x] 确认 GICR `mask_host_private_interrupts` 在本分支
      （已核实：`virtualization/arm_vgic/src/v3/vgicr.rs:43`）
- [x] 读 `map_reserved_memory_region` 实现，确认 host carve-out 机制
      （结论：someboot 把 QEMU RAM 全部标为 Free，MAP_RESERVED 不会自动排除
      Host 堆；固定 carve-out 需自定义 Host FDT reserved-memory 或改 someboot）
- [x] 确认 xtask patch 模式与 `${workspace}` 展开
      （已核实：axvisor 用 `ReplaceDriveOnly`，QemuConfig 统一展开所有 args）
- [x] 构建 ArceOS net 镜像
      （`apps/arceos/udpecho` + `AX_NET_IP=10.0.42.2` 编译期静态 IP；
      ELF 已 objcopy 为 ARM64 Image：
      `tmp/axbuild/rootfs/qemu-aarch64/arceos/arceos-udpecho.bin`）
- [x] 镜像本地化：linux / initramfs / zephyr / arceos 已搬入本仓库
      `tmp/axbuild`，sha256 记录在 net-dual-guest/README.md
- [x] 修 VM toml / README 中跨工作树路径（Guest 镜像全部本地化；
      `--rootfs` 仅是 Host 侧未直通盘，运行参数保留任务一工作树路径）
- [x] `udp_probe` 增加 send 侧 ACK 统计（ACK 率 / RTT / 超时）并重新打包
- [x] `qemu-aarch64-net.toml` 补 QMP/monitor 口，预建 pcap 目录
- [x] 起草 emulated GIC 变体 VM 配置
      （`axvisor-linux-emu-aarch64.toml` / `axvisor-rtos-emu-aarch64.toml`，
      RTOS 侧已切到 ArceOS udpecho + MAP_IDENTICAL）
- [x] 记录 ArceOS 替代 Zephyr 的路线变更与 INTID 48 避让约定
- [x] 预写 T7 pcap 校验脚本（`scripts/test/net-dual-guest/verify_pcap.py`）

## T1-T10 验收（按顺序，QEMU 空闲后执行）

### T1 无网卡双 Guest 基线复验

- [ ] 判据：两 VM boot success；Linux 到 shell 且能执行 `udp_probe`；0 quarantine

### T2 QEMU 布线冒烟

- [ ] 判据：socket 对、filter-dump、`${workspace}` 展开正常；两个 pcap 生成；
      host 日志无异常认领网卡

### T3 映射路线验证

- [ ] 判据：Linux `MAP_RESERVED` / ArceOS dyn+`MAP_IDENTICAL`；日志可查
      GPA==HPA；Linux 能读 initramfs；0 quarantine

### T4 网卡直通 + 中断可达（最高风险关）

- [ ] 判据：Linux eth0 MAC == `52:54:00:12:34:01`（同时证实 slot 顺序）；
      INTID 48/49 计数递增；记录 `interrupt_mode` 结论

### T5 互 ping

- [ ] 判据：Linux→ArceOS ≥20 echo，0% 丢包；两份 pcap 均见 request+reply

### T6 双向 UDP

- [ ] 判据：100 包 ACK≥99%；角色互换再来一轮；日志与 pcap 的 seq 可对账

### T7 pcap 定稿

- [ ] 判据：tshark 校验 ARP/ICMP/UDP、IP/端口/tag 与 manifest 一致、
      两侧互为镜像；一条脚本可复算

### T8 协议可靠性

- [ ] 判据：正常交换、超时重传、重复去重、乱序拒绝、非法参数→ERROR，
      每个状态迁移可复算

### T9 故障注入

- [ ] 判据：QEMU monitor `set_link net-rtos off/on` 断链→heartbeat 超时→
      安全模式→恢复，记录恢复时间；观察 `queue_overflow` 与协议重传的关联

### T10 长稳与冻结

- [ ] 判据：≥30 分钟周期流量；冻结 manifest（MAC/IP/端口/INTID/映射模式/
      interrupt_mode/哈希/命令）

## 执行顺序备注

- T1→T4 严格串行，每步只引入一个变量。
- T8/T9 依赖 T7 的 pcap 定稿。
- 所有 QEMU 步骤与任务一测量窗口互斥。
