# Task-2 双 Guest 网络探路（net-dual-guest）

> 状态：T0 周边工程进行中；任务一 QEMU 已结束，QEMU 冒烟可开始。

## 目标

为赛题二建立一条可验证的 UDP/IP 数据面：Linux 2-vCPU 与 RTOS 1-vCPU 各持一张
独立 virtio 网卡，先打通互 ping 与双向 UDP，再进入协议与故障注入阶段。

## 网络拓扑（QEMU virt AArch64，virtio-mmio）

| Guest | virtio slot | MMIO 地址 | GIC INTID | MAC | IP 规划 |
| --- | --- | --- | --- | --- | --- |
| Linux | slot0 | `0x0a000000` | 48 | `52:54:00:12:34:01` | `10.0.42.1/24` |
| RTOS/ArceOS | slot1 | `0x0a000200` | 49 | `52:54:00:12:34:02` | `10.0.42.2/24` |

QEMU 侧使用两个 `socket` netdev 在同一进程内形成点对点链路（listen/connect
`127.0.0.1:12721`），每个 netdev 挂 `filter-dump`，分别输出
`tmp/net-dual-guest/linux.pcap` 与 `rtos.pcap`，作为“业务确实走 UDP/IP”的证据。
另开一个 QMP UNIX socket（`tmp/net-dual-guest/qmp.sock`），供故障注入阶段
`set_link net-rtos off/on` 断链/恢复使用。

## 文件清单

- `qemu-aarch64-net.toml`：独立于任务一 A/B 的 QEMU 配置，含双 virtio-net 与抓包。
- `axvisor-linux-aarch64.toml` / `axvisor-zephyr-aarch64.toml`：无网卡双 Guest 基线。
- `axvisor-linux-emu-aarch64.toml` / `axvisor-rtos-emu-aarch64.toml`：emulated GIC
  变体（T4 主线）。
- `udp_probe.c`：最小 UDP 收发工具（busybox 没有 `nc`/`ip`）。
- `build-udp-probe.sh`：用仓库里的 aarch64-musl 交叉工具链构建静态探针。
- `pack-initramfs-net.sh`：把探针打进新的 initramfs，不改原镜像。
- `verify_pcap.py`：纯 stdlib 的 pcap 校验脚本（T7 用）。

## 运行

先做无网卡基线复验（机器空闲时）：

```bash
cargo xtask axvisor qemu \
  --config os/axvisor/configs/board/qemu-aarch64.toml \
  --qemu-config scripts/test/net-dual-guest/qemu-aarch64-net.toml \
  --vmconfigs scripts/test/net-dual-guest/axvisor-linux-aarch64.toml \
  --vmconfigs scripts/test/net-dual-guest/axvisor-zephyr-aarch64.toml \
  --rootfs /home/huhu/tgoskits/tmp/axbuild/rootfs/rootfs-aarch64-alpine.img/rootfs-aarch64-alpine.img
```

注意：本工作树没有 `target/debug/tg-xtask`，且机器有已知 libudev 环境问题；可用
任务一工作树已编好的二进制，或按 fable 记录的
`PKG_CONFIG_PATH=/tmp RUSTFLAGS='-L native=/tmp'` workaround 构建。

`--rootfs` 只是 Host 侧未直通给 Guest 的 NVMe 盘，Guest 镜像全部走内存加载；
该 2G 镜像暂不复制进本工作树，运行参数仍指向任务一工作树的产物。Guest 侧
linux/initramfs/zephyr/arceos 镜像已全部本地化，见“镜像与哈希”。

## 探路结论

### Linux 侧基本就绪

- 内核已内置 `virtio_net` + `virtio_mmio`，无需重编。
- busybox 有 `ifconfig/ping/route/udhcpc`，缺 `nc`/`ip`，所以补了 `udp_probe`。

### DMA 映射是加网卡前必须解决的主问题

两个基线 VM 配置目前都是 `map_type = 0`（`MAP_ALLOC`），Day3 用它是为了让
Linux initramfs 的固定 GPA 可翻译。但 QEMU virtio 后端直接按 Guest 写入的
GPA 读写机器内存；`MAP_ALLOC` 下 GPA ≠ HPA，直通 virtio 会写错地址。

候选路线（需要 QEMU 逐项验证）：

1. 固定恒等映射：在 QEMU 8G 内存中选不受 Host 使用的物理区间，用
   `MAP_RESERVED` 让 GPA == HPA，并固定 Guest 链接地址。
   注意：someboot 把 QEMU FDT 里的 RAM 全部标记为 `Free`，`MAP_RESERVED` 本身
   不会把区间从 Host 堆里排除；固定 carve-out 需要额外的 reserved-memory 机制
   （自定义 Host FDT 或 someboot 修改），这是 T3 的第一个待验证前提。
2. 动态恒等映射 + aarch64 布局修正：现有 `BootImagePlan` 已能把 kernel 移到
   实际 HPA，但 ramdisk 仍是固定 GPA；需要补齐 ramdisk 相对偏移迁移，且 Guest
   镜像必须是可重定位的。Linux 可以；ArceOS Rust 应用按 `std PIE` 构建，理论
   上也可行（待构建验证）；预编译 Zephyr 不行。
3. AxVisor 侧实现 virtio-net 模拟：工作量最大，暂不进入主线。

### RTOS 侧需要先定路线

- 本机没有 Zephyr 源码树，只有预编译 `zephyr-qemu`，且镜像里没有网络栈符号，
  直通路线下基本是死路。
- 现有 `arceos-qemu` 只有 virtio block 相关符号，没有 axnet/UDP，需要重新构建
  net 特性镜像；ArceOS Rust 应用按 `std PIE` 构建，优先试
  `MAP_IDENTICAL` 动态恒等，失败再退回固定恒等 + 重链接。
- 建议探路期先走 ArceOS 回退：ArceOS 是仓库自有代码，virtio-net + axnet UDP
  可控性最高，先把 AxVisor 直通问题验证掉，再回头替换 Zephyr。

## 决策记录（评审后）

- **RTOS 路线变更**：探路期用 ArceOS 替代 Zephyr 作为 RTOS 侧 Guest（Zephyr
  无源码且镜像无网络栈）。最终提交时需在提交说明中显式记录该变更，或换回
  Zephyr。
- **中断路线**：优先 emulated GIC（`gppt-gicd/gicr`），passthrough 只做限时
  结论实验。双 Guest passthrough 共享物理 GICD 的 SPI 仲裁是已知高风险。
- **INTID 48 避让约定**：单独跑任务二时 INTID 48 无冲突；若未来把任务一
  synthetic vIRQ 与网络合并到同一运行形态，把 workload vector 改到 50 以上，
  不要用占位设备绕 slot0。
- **测量互斥**：任务一延迟测量与任务二网络压测错峰；本目录 QEMU 配置不用于
  任务一 A/B 收益测量。

## 镜像与哈希

Guest 镜像已复制到本工作树 `tmp/axbuild/rootfs/`：

```text
linux-qemu           4c6c73892466bc47a42c9646930b93945fd1ee2e0e45340ae3013275b7839fad
zephyr-qemu          3886aeccd51758770849287d33289fdc2332263b6377b2f83d9cac9eeb3bc577
arceos-qemu          d99b5c93e6ba4b5166e7cbc28bfb048e6348d658abac8d122ceba4d7b3b9e941
arceos-udpecho.bin   bcea2b6bce4b23da6cb20f2498dbeb59dd275d7b2270bd9e563a5d6a11a8c6ef
initramfs-net        425fccd5278b89639bbc351e3a71f87c839cb5f843a9ece88962f8073461803d
rootfs-alpine(host)  6d5ebe0b90d8bfa4f489e5f2489a1a2c4488514481a89115037c56ef5b93001b
```

`initramfs-net` 是带 `udp_probe` 的版本，Linux VM 配置的 `ramdisk_path` 已指向它。
`arceos-udpecho.bin` 是 T0 用 `cargo xtask arceos build` 构建的 UDP echo 镜像
（`apps/arceos/udpecho`，静态 IP 通过 `AX_NET_IP=10.0.42.2` 编译期注入）。

## pcap 校验

```bash
python3 scripts/test/net-dual-guest/verify_pcap.py \
  tmp/net-dual-guest/linux.pcap tmp/net-dual-guest/rtos.pcap \
  --tag probe --port 4242 --src 10.0.42.1 --dst 10.0.42.2 --min-udp 20
```

## 下一步

1. 跑无网卡双 Guest 基线复验（T1）。
2. QEMU 布线冒烟（T2）：验证 socket 对、filter-dump、QMP、pcap 目录。
3. 验证映射路线（T3）：Linux `MAP_RESERVED` / ArceOS dyn+`MAP_IDENTICAL`，
   先确认 carve-out 或 PIE 可重定位前提。
4. 接通双网卡并验证 INTID 48/49 可达（T4，emulated 主线）。
5. 完成互 ping + 双向 UDP（T5/T6），pcap 定稿（T7）。
6. 协议可靠性 + 故障注入 + 长稳冻结（T8/T9/T10）。

两个已知互斥约定：任务一延迟测量与任务二网络压测错峰；本目录 QEMU 配置不用于
任务一 A/B 收益测量。
