# StarryOS Task2/Task3 独立改造交接说明

## 目标

在不修改、不合并当前 Linux/Zephyr 主线和 `openrace/task3-yolo-ncnn`
分支的前提下，尝试增加一条 StarryOS 加分路径：

```text
StarryOS Guest
    ↓ T2N1 over UDP/IP
Zephyr RTOS Guest
    ↓ STATUS/ACK/ERROR
StarryOS 控制端闭环
```

官网要求是在 `Starry/Linux` 客户机中部署包含神经网络推理的 AI 应用，
通过任务二协议向 RTOS 客户机发送模型输出。StarryOS 替代 Linux 是额外
加分项，最多 4 分；只启动 StarryOS 或只有 syscall 测试不算完整 Task3
替代闭环。

## 分支与工作区边界

- 分支：`openrace/starryos-task2-task3`
- 工作区：`/home/huhu/tgoskits-starry`
- 基线：`2008b0d1b docs(delivery): record integration blockers and priorities`
- 当前 YOLO 分支：`openrace/task3-yolo-ncnn`，工作区
  `/home/huhu/tgoskits-rt`
- 交接窗口只能在 StarryOS worktree 工作，不得修改或 reset 其他 worktree。
- 不要清理用户原有 `results/task1/*` 未跟踪实验目录。

## 已有可复用资产

### 协议

- Rust 协议库：`components/task2-net-protocol/`
- Linux/ArceOS 端点：`apps/arceos/task2-net/`
- Zephyr 端点：`scripts/test/net-dual-guest/zephyr-task2/`
- 协议端口：UDP/4242
- 头部：固定 28 字节 T2N1，Big-Endian，CRC32
- 消息：CONTROL、STATUS、ACK、ERROR、HEARTBEAT

### 主线验收工具

```bash
cargo test -p task2-net-protocol
python3 -m unittest discover -s scripts/test/net-dual-guest -p 'test_*.py'
python3 scripts/test/net-dual-guest/verify_pcap.py \
  --tag '' --require-task2 <starry.pcap> <zephyr.pcap>
```

### StarryOS 现有入口

```bash
cargo xtask starry build --arch aarch64
cargo xtask starry rootfs --arch aarch64
cargo xtask starry qemu --arch aarch64
```

仓库已有 StarryOS 用户态/virtio-net 相关能力和 K230/NNCase 资料，但不能
把 README、配置或历史运行目录当作本分支证据。所有结论必须有当前 HEAD
镜像、日志、pcap 和 SHA256 manifest。

## 必须按阶段推进

### 阶段 A：StarryOS 启动与网络能力勘测

目标：确认当前 HEAD 的 AArch64 StarryOS 能启动、识别 virtio-net，并能执行
最小用户态程序。

验收至少包括：

- StarryOS AArch64 kernel/rootfs 构建成功；
- QEMU 启动日志有明确成功 marker；
- virtio-net 设备初始化日志；
- 用户态程序可以运行；
- 缺少 socket/网络 syscall 时，记录精确 syscall 和 errno，不绕过问题。

如果 AArch64 StarryOS 当前不可运行，应先记录外部阻塞，不伪造 Task2/Task3
闭环证据。

### 阶段 B：StarryOS ↔ Zephyr 的 Task2 最小闭环

先不接 AI，只实现：

```text
StarryOS → CONTROL → Zephyr → STATUS/ACK → StarryOS
```

优先复用 `components/task2-net-protocol`，为 StarryOS 写最小用户态端点；
不要先改协议格式。需要验证：

- VirtIO-net / IPv4 / UDP socket；
- CONTROL、STATUS、ACK；
- session mismatch、乱序、重复和重传；
- 双端 pcap 通过 `verify_pcap.py --require-task2`；
- blackout → Safe → recovery。

阶段 B 未通过前，不进入 AI 或 ncnn 集成。

### 阶段 C：StarryOS 内真实神经网络推理

优先顺序：

1. 先尝试复用现有纯 Rust CNN（`components/task3-model`），验证 StarryOS
   用户态能加载静态权重并完成真实前向推理；
2. 再尝试 ncnn/YOLO。ncnn 需要 AArch64 musl 交叉编译、模型转换、C++
   runtime 和 Guest 文件加载，不能把主机 ONNX fixture replay 当作完成。

真实 Task3 证据必须有：

- 模型文件在 StarryOS Guest 内；
- Guest 内 runtime/前向推理日志；
- `TASK3_MODEL_READY`、`TASK3_INFER`、`TASK3_DETECTION`；
- 模型输出经 T2N1 CONTROL 发送给 Zephyr；
- Zephyr 执行控制并返回 STATUS；
- 模型加载失败、推理超时或非法输出进入可观察 Safe 路径。

### 阶段 D：完整故障和交付证据

只有 A/B/C 都通过后，才运行：

- 正常双 Guest 闭环；
- ACK-drop；
- out-of-order；
- invalid-parameter；
- blackout → Safe → recovery；
- 双端 pcap、完整日志和 SHA256 manifest；
- 与 Linux 主线的延迟、控制误差、稳定时间或识别准确率对比。

## 严格禁止的表述

- 不能把 StarryOS 启动写成 StarryOS Task3 已完成；
- 不能把主机 `onnxruntime` fixture 运行写成 Guest 内 YOLO 推理；
- 不能使用共享内存、HyperCall 或裸 MMIO 替代 Task2 主数据通道；
- 不能在本分支直接合并 `origin/dev` 后跳过重新回归；
- 不能为了通过单个测试修改 T2N1 协议语义。

## 停止条件

遇到以下任一情况，应保存诊断并在交接结果中标为 blocked，不要伪造闭环：

- 缺少 AArch64 StarryOS kernel/rootfs 或 QEMU；
- virtio-net、IPv4、UDP socket 或必要 syscall 缺失；
- ncnn/模型转换工具无法为目标 Guest 交叉编译；
- Guest 内模型加载失败且没有可审查的修复路径；
- StarryOS 端点无法通过双端 pcap 和 T2N1 verifier。

## 提交规则

每个完整阶段单独提交并推送到：

```text
origin/openrace/starryos-task2-task3
```

使用 Conventional Commit，例如：

```text
feat(starry): add task2 udp endpoint smoke path
test(starry): validate task2 t2n1 guest loop
feat(starry): run in-guest cnn inference
docs(delivery): record starryos bonus evidence
```

最终结果必须明确标注：`complete`、`partial` 或 `blocked`，并给出证据路径、
命令、镜像哈希和限制。
