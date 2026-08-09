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

补充验证（T3 后半段）：

- ArceOS `MAP_RESERVED` @ `0x8020_0000` + 完整 Host DTB（`dtb_path`）可正常
  启动：`eth0` 注册、静态 IP `10.0.42.2/24`、`udpecho ready on 0.0.0.0:4242`。
- 结论：ArceOS 早期 boot 依赖完整 DTB；AxVisor 从 VM 配置生成的 DTB 会让
  ArceOS 在 0x48 处 MMIO fault。

## T4 网卡直通 + 中断可达（2026-08-09）

状态：**未通过（卡在 virtio IRQ 路由）**

做了什么：

- Linux 透传 `/virtio_mmio@a000200`（slot1，INTID 49），ArceOS 透传
  `/virtio_mmio@a000000`（slot0，INTID 48），均使用 QEMU dump 的完整 DTB。
- 尝试 passthrough 与 emulated GIC 两种 `interrupt_mode`。

结果：

- 两个 VM 都能 boot success，不再有地址冲突（去掉 `excluded_devices`，改用
  slot 分工避免 4K 对齐合并）。
- 但两个 Guest 都探测不到 virtio 网卡：Linux `TASK2_NO_ETH0`，ArceOS
  `No network device found!`。
- emulated GIC 下出现持续 `Unhandled IRQ ... hwirq 27` 风暴，说明 virtio
  物理中断没有被正确路由/掩码。

遗留问题：

1. Guest FDT 中的 virtio 节点与 stage-2 MMIO 映射是否真正建立（需要核对
   `parse_passthrough_devices_address` 和 `setup_guest_fdt_from_vmm`）。
2. virtio-net 的 SPI（48/49）在 passthrough/emulated 两种模式下如何正确
   路由到 Guest，以及 Host 侧如何掩码这些 IRQ 避免风暴。
3. Linux 2-vCPU 的 PSCI CPU_ON 仍未实现（当前用 `maxcpus=1` 绕过）。

## T4 第二轮：virtio-net-pci 路线（2026-08-09）

状态：**方向确认有效，仍需收尾**

确认结果：

1. **ArceOS 不探测 virtio-mmio**：`rdrive` 只从 PCI 网卡注册设备；因此
   virtio-mmio 直通在 ArceOS 侧无效（这也是 T4 第一轮“No network device”的
   直接原因）。
2. **改走 `virtio-net-pci` 后 ArceOS 能注册网卡**：双 Guest 都 boot success，
   ArceOS 注册 `eth0`（静态 `10.0.42.2/24`）和 `eth1`（DHCP），
   `udpecho ready on 0.0.0.0:4242`；`linux.pcap` 已开始有流量。
3. **Linux 用完整 PCI DTB 时出现 GIC/ITS 警告**：
   `GICv3: Expected reserved range ... not found` / `memory probably corrupted`，
   Linux 未到 init。原因大概率是完整 DTB 的 GIC ITS/保留内存与 AxVisor 生成
   的 Guest 内存布局不一致，需要裁剪 DTB 或修正内存保留区。
4. **任务一 realtime injector 与任务二冲突**：`VIRQ_INJECT ... status=error`
   持续出现（vector 48/49 注入 VM2 失败），任务二实验应禁用 realtime probe
   或把注入 vector 改到 50+。

下一步：

- 为 Linux/ArceOS 各生成只含自己 NIC 的 PCI DTB（或实现 FDT 设备过滤），
  避免两个 Guest 都看到两张网卡。
- 修正提供 DTB 的 GIC ITS/保留内存与 Guest 内存布局的一致性。
- 任务二运行禁用 realtime injector；2-vCPU Linux 后续补 PSCI CPU_ON。

剩余问题：

- Linux `MAP_RESERVED` / `MAP_IDENTICAL` 的映射路线仍待验证（当前以
  `MAP_ALLOC` 1-vCPU 跑通，2-vCPU 的 PSCI CPU_ON 尚未实现）。
- ArceOS `MAP_IDENTICAL` 的 0x48 MMIO fault 需要单独定位；下一步试
  ArceOS `MAP_RESERVED` 固定恒等（link 地址 `0x8020_0000`）。
