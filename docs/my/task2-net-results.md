# Task-2 网络探路实验结果

> 分支：`openrace/task2-net`
> 机器：QEMU AArch64 + AxVisor，任务一 A/B 已结束

## T1 无网卡双 Guest 基线复验（2026-08-09）

状态：**通过（Linux shell 证据待串口分离后补强）**

命令：

```bash
FEATURES=openrace-realtime timeout 90 /home/huhu/tgoskits-realtime/target/debug/tg-xtask \
  axvisor qemu \
  --config os/axvisor/configs/board/qemu-aarch64.toml \
  --qemu-config scripts/test/net-dual-guest/qemu-aarch64-baseline.toml \
  --vmconfigs scripts/test/net-dual-guest/axvisor-linux-aarch64.toml \
  --vmconfigs scripts/test/net-dual-guest/axvisor-zephyr-aarch64.toml \
  --rootfs /home/huhu/tgoskits/tmp/axbuild/rootfs/rootfs-aarch64-alpine.img/rootfs-aarch64-alpine.img
```

结果：

- `VM[1] boot success` / `VM[2] boot success`：通过。
- DMA quarantine：0 条：通过。
- Zephyr `PROJECT EXECUTION SUCCESSFUL`：通过。
- Linux shell（`rdinit=/bin/sh`）：未拿到干净证据。两个 Guest 都直通同一个
  PL011，串口输出互相穿插，`echo T1_LINUX_OK` 未能可靠送达/回显。

结论：迁移后的无网卡双 Guest 基线本身能启动；下一步需要先解决共享串口的
console 隔离（或至少用可锚定的输出协议），否则 T5/T6 的日志对账不可靠。

## T2 QEMU 布线冒烟（2026-08-09）

状态：**通过**

命令：与 T1 相同，`--qemu-config` 换成
`scripts/test/net-dual-guest/qemu-aarch64-net.toml`（双 virtio-net + filter-dump
+ QMP），VM 配置仍为无网卡基线。

结果：

- QEMU 正常拉起 socket netdev（listen/connect `127.0.0.1:12721`）、两个
  filter-dump 和 QMP UNIX socket，无参数错误。
- `VM[1]` / `VM[2]` boot success，0 quarantine。
- `tmp/net-dual-guest/linux.pcap` / `rtos.pcap` 在运行期间创建（当前为空捕获，
  只有 24 字节 pcap 头，符合“未挂直通”预期）。
- `qmp.sock` 在 QEMU 运行期间存在（退出后被 QEMU 清理），确认 QMP 可用。

结论：双网卡布线、抓包和 QMP 基础设施可用，进入 T3 映射验证。

## T3 映射路线验证（2026-08-09）

状态：**部分通过；Linux 侧已打通到 init，RTOS/MAP 路线仍待继续**

实验：

1. Linux `MAP_RESERVED`（`axvisor-linux-reserved-aarch64.toml`）：VM boot
   success，但内核没有任何 console 输出（卡在 PSCI 探测之后）。
2. ArceOS `MAP_IDENTICAL` + emulated GIC（`axvisor-rtos-emu-aarch64.toml`）：
   VM boot success 后立即 MMIO fault：`read guest MMIO ... at 0x48`。
3. Linux `MAP_IDENTICAL`：同样无 console 输出。

定位到并已修复的问题：

- **Guest DTB 没有写入 VM 配置的 cmdline**：`patch_chosen()` 只会改写已存在的
  bootargs，不会用 `kernel.cmdline` 覆盖，导致 Guest Linux 继承外层 QEMU 的
  bootargs（没有 earlycon/console），静默卡住。已修复：
  `tree.patch_chosen(initrd, bootargs)` 现在接收并写入 guest cmdline，
  `virtualization/axvm/src/boot/fdt/core/tree.rs`。
- **aarch64 identity 内存下 ramdisk 不迁移**：补了
  `BootImagePlan` 的 ramdisk 相对偏移迁移，与 kernel 一起搬到动态 HPA，
  `virtualization/axvm/src/vm/boot.rs`。
- **HVC/SMC 返回后 PC 未前进**：ELR_EL2 指向触发指令，返回前必须 +4；
  修复 `virtualization/arm_vcpu/src/exception.rs` 后，Linux 从
  `psci: probing...` 卡死变为继续启动。
- **initramfs `/dev/console` 是普通文件**：内核把 init 的 fd 0/1/2 指向该
  文件，脚本输出全部落盘不可见；新增静态 C init（`task2-init.c`）先重建
  设备节点并把 fd 指向 console，再执行 ifconfig/udp_probe。

修复后验证：Linux 单 Guest（`MAP_ALLOC`，1-vCPU）已能打印
`Linux version`、`earlycon`、`psci: PSCIv0.2 detected`，并进入
`/bin/task2-init`：`TASK2_INIT_START`、`TASK2_NO_ETH0`、
`TASK2_UDP_RECV_STARTED`、`udp_probe: recv on 0.0.0.0:4242` 均出现，
无 kernel panic。

剩余问题：

- Linux `MAP_RESERVED` / `MAP_IDENTICAL` 的映射路线仍待验证（当前以
  `MAP_ALLOC` 1-vCPU 跑通，2-vCPU 的 PSCI CPU_ON 尚未实现）。
- ArceOS `MAP_IDENTICAL` 的 0x48 MMIO fault 需要单独定位；下一步试
  ArceOS `MAP_RESERVED` 固定恒等（link 地址 `0x8020_0000`）。
