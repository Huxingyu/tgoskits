# Task-3 AI 控制闭环设计文档

> 分支：`openrace/task3-clean`（基于 Task-2 基线 `01f77307e`）
> 状态：官方 5 项要求完成；另含"链路故障安全恢复"附加扩展（可选能力）## 1. 目标与边界

Task-3 的目标是在既有 Task-2 双 Guest UDP/IP 链路上，实现一个**可复现、可量化、
可演示**的 AI 控制闭环：

```text
Zephyr 虚拟对象/传感器
        │ T2N1 STATUS
        ▼
Linux Guest 时序模型推理
        │ T2N1 CONTROL
        ▼
Zephyr 应用控制并更新虚拟对象
        │ T2N1 STATUS
        └────────── 回到 Linux
```

本方案是 QEMU 上的**软件在环（SIL）验证**。明确不声称：

- 已在真实板卡上运行；
- QEMU 测得的延迟是硬实时保证；
- 冻结场景之外的泛化能力。

## 2. 系统架构

### 2.1 平台

| 项 | 值 |
|---|---|
| QEMU | 10.2.1，AArch64，`virt,virtualization=on,gic-version=3` |
| 虚拟机监控 | AxVisor，虚拟 virtio-mmio 端点 + 内部 L2 软交换 |
| Linux Guest | 控制器 + 模型推理（initramfs 静态加载，musl 用户态二进制） |
| Zephyr Guest | 虚拟对象 + 执行器（board `qemu_cortex_a53`，Zephyr 4.4.99） |
| 数据链路 | 两个独立 VirtIO-MMIO 端点，经 Axvisor 内部 L2 软交换互联 |
| 端点 | Linux `10.0.42.15:4242` ↔ Zephyr `10.0.42.2:4242` |

数据面全部在 AxVisor 内部完成：每个 guest 通过
`[[devices.virtual]] model = "virtio-net"` 获得一个虚拟 virtio-mmio 端点
（0x0a00_0000，wired IRQ 48），端口接入 hypervisor 内建 L2 软交换
（SwitchPort + ingress 队列 + poll_dma + vIRQ）。guest 间流量不依赖任何
QEMU 网卡、socket 对、抓包代理或外部物理链路；QEMU 仅承载宿主机运行环境。
协议、模型、两端应用与传输介质解耦，同一套实现在开发板形态下无需改动。

### 2.2 协议与消息

沿用 Task-2 的 T2N1 可靠消息（CONTROL / STATUS / ACK / HEARTBEAT / ERROR）。
Task-3 采用请求-响应模式：一条 CONTROL 对应一条 STATUS，控制周期 100 ms
（5–10 Hz），不引入高频遥测流，因此不修改协议状态机。

## 3. 冻结场景与参数

正式对比前冻结以下参数（固定 seed，看完结果不修改场景）：

```text
state 范围     0..1000
output 范围    0..1000
base_loss      15
nonlinear_loss 120
response       0.35
目标轨迹       0-5s: 300, 5-15s: 800, 15-25s: 500
扰动轨迹       8s: +150 负载, 17s: -150 负载
控制周期       5-10 Hz（请求-响应）
baseline       Kp=2 纯 P 控制器（冻结参数，非故意调差）
```

对象更新（Zephyr 整数语义，C 除法截断向零，Python 训练端逐点复刻）：

```text
loss(state) = base_loss + trunc(nonlinear_loss * state² / 1_000_000)
state_next = clamp(state + trunc(response * (output - state)) - loss + disturbance, 0, 1000)
```

## 4. 模型设计与训练

### 4.1 模型结构

1D 时序 CNN，纯 Rust `no_std` 前向推理，权重 `include_bytes!` 嵌入：

```text
输入：64 个历史采样点 × 4 特征 [state, target, error, prev_output]
Conv1D 4→32 k=5 ReLU
Conv1D 32→64 k=5 ReLU
Global Average Pooling
Dense 64→32 ReLU
Dense 32→1
```

- 参数量：13,089；MACs 估算：~0.7M/推理；
- 权重：`components/task3-model/model/weights.bin`（DAgger 最终产物），
  SHA-256 与训练器哈希记录于 `model/model.json`（`trainer=dagger_train.py`、
  `dagger_iterations=6`、`dagger_epochs=25`、`dagger_closed_loop_weight=3`）；
- Guest 内推理：均值 11.3 ms、p95 14.6 ms（QEMU TCG 环境，`infer_us` 实测）。

### 4.2 训练方法：残差 + DAgger

- **残差学习**：模型只学习冻结 P 控制器缺失的损耗/扰动补偿项，P 项保证闭环
  稳定（固定场景闭环 RMSE 33，真实双 Guest 运行 RMSE 29.3）。
- **teacher**：gain=0.5 逆控制跟踪策略。
- **DAgger 真闭环**：逐 100 ms `plant.step` rollout，模型输出真实反馈进状态；
  6 轮、每轮 120 个随机 episode、teacher 打标、3 倍重采样（参数记录于
  `model.json`）。
- **数据**：400 个随机 episode（随机目标阶梯/扰动/初值），94,800 样本；
  冻结的固定测试场景不进入训练集。
- **特征契约**：`scripts/task3/features.py::build_window` 为唯一实现，
  数据集/DAgger/评估/Rust guest 全部复用；Rust `build_features` 镜像并由
  golden-window 测试跨语言锁定（误差 < 1e-12）。
- **golden 测试**：卷积对照 torch f64 参考（1e-9），输入含非对称模式（斜坡）。
- **元数据一致性**：`dagger_train.py` 训练结束后同步刷新 `model.json`
  （权重哈希/训练器/参数），`export_golden.py` 从最终 `weights.bin` 重新生成
  Rust golden 向量，保证"权重 ↔ 推理 ↔ 元数据"三者一致。

## 5. 控制器、baseline 与延迟测量

### 5.1 控制器

- baseline：`output = clamp(Kp * error + bias, 0, 1000)`，Kp=2、bias=0；
- AI 模式：`output = clamp(P 输出 + model(features) * 1000, 0, 1000)`，Zephyr
  侧仍做最终限幅与 Safe 兜底；
- 请求-响应循环：收到 STATUS 后才发下一条 CONTROL（`request_in_flight` 跟踪），
  模型输出进入 CONTROL.value，通过日志与 request ID 关联。

### 5.2 延迟测量方法（同侧往返）

测量在 **Linux 控制器同侧时钟** 完成，不依赖跨 Guest 时钟同步：

- `rtt_ms = STATUS 接收时刻 − CONTROL 发出时刻`（`main.rs` `on_status`，
  同一 Linux 侧 `Instant` 时钟，整数毫秒）；
- 推理耗时 `infer_us` 在发送前用 `Instant` 单独计时（微秒级）；
- `task3_metrics.py` 从 `TASK3_STATUS_RECEIVED`/`TASK3_INFER` 日志解析并汇总
  均值/p95。

**周期级延迟的构成**：100 ms 限速睡眠 + 模型推理 + 网络传输（软交换/直连）+
RTOS 处理与 plant 更新 + STATUS 回传。因此 `rtt_ms` 是**整周期延迟**，
不是纯网络往返；AI 模式比 baseline 多出的 ~13 ms 主要来自模型推理被计入窗口。

**误差来源与精度范围**：

| 来源 | 说明 |
|---|---|
| 仿真抖动 | QEMU TCG 调度抖动，绝对值不具硬实时含义 |
| 采样粒度 | 请求-响应 100 ms 周期，只能观测整周期完成时刻 |
| 日志抽样 | 只统计成功完成周期的记录，失败/重传周期不计入 |
| 时间分辨率 | `rtt_ms` 整数毫秒（截断，±1 ms 舍入量级）；`infer_us` 微秒 |
| 时钟边界 | 无跨 Guest 共享时间源；同侧测量规避时钟偏差，但无法分离单程耗时 |

建议解读：`rtt_ms` 用于对比 AI/baseline 的**周期级控制节奏**与系统端到端耗时
量级；精确到毫秒级，不做亚毫秒结论。

## 6. 附加扩展：链路故障安全恢复

> 说明：本扩展不属于官方 5 项要求，作为可选能力保留（`scripts/task3/run-task3-switch-fault.sh`
> 的 `virtnet drop` 黑障、恢复路径实现、`results/task3/switch/fault-*/` 证据）。

### 6.1 故障注入

在 guest 链路按时间窗口丢弃**全部帧**（双向），模拟运行中链路中断；
窗口结束自动恢复转发。hypervisor 级黑障门（`virtnet drop on/off`）直接
作用于软交换的端口边界，两端协议栈照常运行：

```text
黑障 25s→~35s（双向全丢）→ 双方重传耗尽/心跳超时进入 Safe
→ 黑障结束 → heartbeat 恢复 → 可靠流重同步 → 控制环自动续跑
```

（在 QEMU socket 直连环境下，等价故障由 `ack_drop_proxy.py --blackout-*`
在链路上丢弃帧实现，见 `results/task3/fault/` 的早期证据。）

### 6.2 恢复路径实现

完成态代码包含以下设计，保证断链后安全退出与恢复：

1. **Safe 进入**：重传耗尽（`RetryExhausted`）或心跳超时（`HeartbeatTimeout`）
   时双方进入 Safe，控制器复位应用层 in-flight 标记；
2. **可靠流重同步**：Safe→Active 时协议将 `next_tx/next_rx/pending` 重置，
   双方从序号 1 重新同步（Rust `task2-net-protocol` 与 Zephyr C 双端一致，
   含回归测试）；
3. **ACK 竞争容忍**：STATUS 先于其 CONTROL 的 ACK 到达时，下一条 CONTROL
   延迟到 Acknowledged 事件续发（`TASK2_CONTROL_DEFERRED`），不视为致命；
4. **发送稳健性**：非阻塞 UDP 发送遇 `WouldBlock` 做有界重试
   （`send_datagram`，500 ms）。

## 7. 实验证据

### 7.1 AI/baseline 对比（软交换链路：2 AI + 3 baseline，各 ~35 s）

| 指标 | AI (n=2) | baseline (n=3) |
|---|---|---|
| 整体 RMSE | 40.7 / 41.6 | 195.9 / 196.9 / 197.6 |
| t300 段 RMSE（0-5s） | 66.7 / 69.7 | 79.7–81.3 |
| t800 段 RMSE（5-15s） | 47.5 / 53.1 | 236.5–240.7 |
| t500 段 RMSE（15-25s） | 30.4 / 29.6 | 192.4 |
| t500 稳态误差 | ~2（498 vs 500） | ~192（308 vs 500） |
| t500 调节时间（5% 带） | 1371–1588 ms | 未收敛 |
| Guest 推理耗时 | 均值 ~7.6 ms（QEMU TCG） | - |
| 周期级延迟（整周期） | 均值 ~174 / ~192 ms | 均值 ~159–162 ms |

原始数据：`results/task3/switch/`（每 run 的 `run.log` + 双端 pcap +
`summary.csv` + `comparison.png`）。双端 pcap 的 T2N1 帧账本完全一致
（`verify_pcap.py` PASS：871 帧/端，CONTROL 204 + STATUS 205 + ACK 410 +
HEARTBEAT 52）。

**同一实验在 QEMU socket 直连环境下的验证**（更早的实验环境，传输层为
QEMU socket 对 + filter-dump 抓包）：3 AI + 3 baseline 各 ~39 s，整体
RMSE 29.2–29.3 vs 190.6–191.3，周期延迟 ~104 ms vs ~91 ms，数据见
`results/task3/run-{1..6}.csv`。两组环境的 AI/baseline 结论一致；软交换
链路的延迟更高、RMSE 更大（原因见 §9 的延迟特性说明）。

### 7.2 故障安全恢复（附加扩展）

| 事件 | 观测（软交换链路） | 观测（QEMU socket 直连环境） |
|---|---|---|
| 黑障窗口 | 25s→~35s，`virtnet drop` 双向全丢 | 25s→35s，代理丢弃 102 帧（双向） |
| Safe 进入 | 双方 RetryExhausted / HeartbeatTimeout 进入 Safe | 同左 |
| 恢复 | `TASK2_RECOVERED` 后可靠流从序号 1 重同步 | 同左 |
| 续跑 | 恢复后 29 个 STATUS 周期（4.8s，0 协议错误） | 恢复后 82 个 STATUS 周期，周期延迟 ~74–109 ms，0 协议错误 |

证据：`results/task3/switch/fault-switch-fault-run1/`（guest 日志 + 双端
pcap）与 `results/task3/fault/`（guest/proxy 日志 + 双端 pcap + SHA-256）。

### 7.3 证据链工具

| 能力 | 实现 |
|---|---|
| 抓包 | `virtnet capture on/off/dump`：在端口边界记录每帧（时间戳+帧字节），shell 流式导出为经典 pcap（`switch.vm1.pcap` / `switch.vm2.pcap`） |
| 故障注入 | `virtnet drop on/off`：双向丢弃全部帧的 hypervisor 级黑障门，两端协议栈照常运行 |
| 端口审计 | `virtnet show`：端口表（VM/MAC/状态）+ 黑障/抓包开关 |
| 自动化 | `serial_console.py` 通过 QEMU serial socket 全生命周期驱动（boot→抓包→黑障→恢复→pcap 导出→QMP 退出），`run-task3-switch.sh` / `run-task3-switch-fault.sh` 编排 |

## 8. 复现命令

```bash
# 训练（固定 seed；dagger 结束后自动刷新 model.json）
python3 scripts/task3/generate_dataset.py --train-episodes 400 --val-episodes 40
python3 scripts/task3/train_model.py --epochs 60
python3 scripts/task3/dagger_train.py --iterations 6 --epochs 25 --closed-loop-weight 3
python3 scripts/task3/export_golden.py && cargo test -p task3-model

# 构建 guest（baseline / AI）
TASK3_CONTROL_LOOP=1 bash scripts/test/net-dual-guest/build-linux-task2.sh
TASK3_CONTROL_LOOP=1 TASK3_AI=1 bash scripts/test/net-dual-guest/build-linux-task2.sh
bash scripts/test/net-dual-guest/build-linux-initramfs.sh
bash scripts/test/net-dual-guest/build-zephyr-task2.sh   # 需 Zephyr SDK 与源码

# 实验（AI/baseline 对比；故障安全恢复为附加扩展；软交换链路为当前数据面）
bash scripts/task3/run-task3-switch.sh ai-runX ai
bash scripts/task3/run-task3-switch.sh baseline-runX baseline
bash scripts/task3/run-task3-switch-fault.sh fault-runX

# QEMU socket 直连环境下的早期实验流程（数据见 results/task3/）
bash scripts/task3/run-task3-experiment.sh ai-runX ai
bash scripts/task3/run-task3-experiment.sh baseline-runX baseline
bash scripts/task3/run-task3-fault.sh fault-runX

# 指标（以软交换链路为例）
python3 scripts/test/net-dual-guest/task3_metrics.py <logs...> \
  --out-dir results/task3/switch --label switch --modes ai,ai,baseline,baseline,baseline \
  --plot results/task3/switch/comparison.png
```

## 9. 已知边界与诚实声明

- 所有结论基于 QEMU SIL 验证，不声称真实板卡或硬实时保证；
- 冻结场景外推有限：模型只在随机化训练分布上验证；
- t800 目标（800）超过 plant 可持续上限（~760，含扰动 ~880），AI 以
  ~790-810 逼近而非达到；
- baseline 为冻结的 Kp=2 纯 P 控制器，非故意调差；
- "3+3 组"是同冻结场景的重放（可复现性强，非统计显著性样本）；
- 周期级延迟含限速与推理，不作为纯网络 RTT 解读（见 §5.2）；
- 故障安全恢复为附加扩展，`set_link` 在本环境无效属平台边界，故障注入以
  `virtnet drop` 黑障门（QEMU socket 直连环境为 P3 代理黑障）为准；
- **软交换链路的 RX 交付特性**：交付依赖 vCPU 运行循环的 `poll_dma`，而非
  直连设备的即时 IRQ。实测中位控制周期 ~130 ms（rtt 约束），存在周期性
  ~300 ms 尖峰（约 2 次/s，与心跳送达时的 vCPU 唤醒竞争相关）；周期仍处于
  5–10 Hz 设计范围。该尖峰使 AI 模型的时间窗采样不均匀，RMSE 由 socket
  直连环境的 ~29 升至 ~41，但 AI/baseline 的 ~4.8 倍差距与全部结论保持成立；
- 板上部署时物理网卡仅作外部管理，guest 间数据面不经物理链路。

## 10. 完成定义对照

### 官方 5 项要求

| 要求 | 状态 |
|---|---|
| ① Linux 客户机部署 NN 推理应用并经 T2N1 发送模型输出 | ✅ |
| ② RTOS 按 AI 输出调整控制并执行可观察动作（日志/plant 状态） | ✅ |
| ③ 完整闭环（输入→推理→跨客户机→控制→状态回传） | ✅ |
| ④ 端到端延迟测量并说明方法/误差来源/精度范围 | ✅（§5.2） |
| ⑤ 固定参数基线对比，≥2 项指标 | ✅（RMSE/调节时间/超调/延迟/推理耗时） |

### 附加扩展与交付

| 项 | 状态 |
|---|---|
| 链路故障安全恢复（黑障→Safe→重同步→续跑） | ✅（2 次复现，非官方要求） |
| 原始日志、CSV、模型哈希、复现命令 | ✅（`results/task3/` + 本文档） |
| Task-2 原有测试/证据不回归 | ✅（协议 20 测试 + Python 20 测试） |
| 演示视频 | 暂缓（不在本分支范围） |
