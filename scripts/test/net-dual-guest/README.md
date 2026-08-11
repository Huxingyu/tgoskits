# Task-2 P1–P3 网络验证资产

本目录把单 Guest、双 Guest 和协议/故障实验拆成可复算的输入与工具。它不替代
AxVisor 的设备图隔离证明：当前 Guest 物理设备选择器主要按 FDT path 工作，
所以启动 P2 前必须先验证两个 Guest 的最终设备集合不相交。

## P1：单 Guest 网络

Linux 用户态 T2N1 端点的编译产物必须按角色分别生成并立即复制。使用下面的入口
会为 controller 和 managed 使用独立的 Cargo target 目录，并在启动前拒绝相同镜像
哈希：

```bash
scripts/test/net-dual-guest/build-linux-task2.sh
cat tmp/net-dual-guest/linux-task2/manifest.toml
```

该脚本只生成静态 AArch64 Linux userspace binary，不等同于 Linux Guest 已经启动；
后续 Linux initramfs 组装和 AxVisor 启动仍必须把 manifest、kernel、initramfs 与
Guest 日志一起归档。

先验证工作树和工具：

```bash
python3 scripts/test/net-dual-guest/validate_manifest.py \
  scripts/test/net-dual-guest/manifest.toml
bash scripts/test/net-dual-guest/build-tools.sh
```

ArceOS 侧 endpoint 使用：

```bash
cargo xtask arceos build \
  --package arceos-task2-net \
  --arch aarch64 \
  --config apps/arceos/task2-net/build-aarch64-unknown-none-softfloat.toml
```

外层 QEMU 的单网卡配置是 `qemu-aarch64-p1.toml`。运行器必须把生成的 Guest
VM 配置显式选择为 `virtualized` + 一个明确的设备身份；如果只能选择
`/pcie@10000000` 整个 controller，应将实验标记为“设备隔离未证明”，不得记为 P1
直通成功。

P1 通过条件：Guest 日志出现 `TASK2_NET_CONFIGURED`/`TASK2_READY`，驱动日志包含
目标 MAC，IRQ 计数递增，且 `p1.pcap` 通过 pcap parser 检查。

## P2：双 Guest 数据面

`qemu-aarch64-p2.toml` 创建两个独立的 `virtio-net-device` MMIO endpoint，分别由
`/virtio_mmio@a003e00` 和 `/virtio_mmio@a003c00` 选择；两个 socket netdev 通过
`127.0.0.1:12721` 形成点到点链路。两侧固定 MAC、挂 `filter-dump`，并提供 QMP
UNIX socket：

```bash
python3 scripts/test/net-dual-guest/validate_manifest.py \
  scripts/test/net-dual-guest/manifest.toml
```

验证双侧 pcap（旧式 `udp_probe`）：

```bash
python3 scripts/test/net-dual-guest/verify_pcap.py \
  tmp/net-dual-guest/linux.pcap tmp/net-dual-guest/rtos.pcap \
  --tag probe --port 4242 --min-udp 20
```

验证协议帧：

```bash
python3 scripts/test/net-dual-guest/verify_pcap.py \
  tmp/net-dual-guest/linux.pcap tmp/net-dual-guest/rtos.pcap \
  --tag '' --port 4242 --min-udp 20 --min-ack-rate 99 --require-task2
```

P2 通过条件是：Linux 与 RTOS 的 MAC、IP、MMIO FDT path、host SPI、Guest INTID、
MMIO/GPA/HPA 以及最终设备集合均不相同；双向 UDP 至少 20 个 request/reply，两个
pcap 都能复算相同的方向和序号。历史上的 ArceOS 探路镜像只能作为拓扑预检，不能
替代最终 Linux + Zephyr 验收证据。

最终 Linux + Zephyr 长稳使用独立的 1 小时配置和 Debug AxVisor 构建：

```bash
cargo xtask axvisor qemu \
  --config /tmp/task2-axvisor-qemu-debug.toml \
  --qemu-config scripts/test/net-dual-guest/qemu-aarch64-p2-stability-1h.toml \
  --vmconfigs scripts/test/net-dual-guest/vm-aarch64-p2-linux.toml \
  --vmconfigs scripts/test/net-dual-guest/vm-aarch64-p2-rtos.toml
```

运行至少 3600 秒后通过 QMP `quit` 结束，再使用 `verify_pcap.py` 和
`verify_isolation.py` 校验双侧抓包账本及 identity DMA/stage-2/IRQ 证据；完整结果
和哈希见 `task2-run-2026-08-11.md`。

## P3：协议和故障注入

协议核心在 `components/task2-net-protocol`，不依赖 socket 或 Guest runtime：

```bash
cargo test -p task2-net-protocol
cargo clippy -p task2-net-protocol --all-targets -- -D warnings
```

覆盖内容包括：

- `T2N1` 固定帧、长度、flag、CRC32 和 typed payload 校验；
- ACK、stop-and-wait 重传和最大重传耗尽；
- 重复帧只 ACK 不重复交付；
- 乱序帧进入安全状态并回复 `OUT_OF_ORDER`；
- 非法参数回复 `INVALID_PARAMETER`；
- heartbeat 超时进入 `Safe`，收到合法 heartbeat 后恢复 `Active`。

QMP 链路故障必须显式区分“控制 socket 断开”和“数据链路 down/up”。后者示例：

```bash
python3 scripts/test/net-dual-guest/qmp_link.py \
  tmp/net-dual-guest/qmp.sock net-rtos off
python3 scripts/test/net-dual-guest/qmp_link.py \
  tmp/net-dual-guest/qmp.sock net-rtos on
```

P3 运行证据应同时保存 QMP 返回值、Guest `TASK2_SAFE`/`TASK2_STATUS` 日志、重传
次数和恢复时间。QMP 命令成功但 Guest 没有进入安全状态，不算故障注入通过。
