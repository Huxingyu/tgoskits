# Task-3 AI 控制闭环实施 TODO

## 1. 文档目标

本文是基于当前 Task-2 双 Guest UDP/IP 链路的 Task-3 最小可交付方案。
目标是尽快完成一个可复现、可量化、可录制演示的闭环，不把 Task-1、真实开发板或
复杂通用协议作为前置条件。

Task-3 的主线验收链路为：

```text
Zephyr 虚拟对象/传感器
        │ 现有 T2N1 STATUS
        ▼
Linux Guest 时序模型推理
        │ 现有 T2N1 CONTROL
        ▼
Zephyr 应用控制并更新虚拟对象
        │ 现有 T2N1 STATUS
        └─────────────── 回到 Linux
```

本方案是 QEMU 上的软件在环（software-in-the-loop, SIL）验证。它不声称已经完成
真实板卡控制，也不把 QEMU 测得的延迟表述为真实硬件的硬实时保证。

## 2. 已冻结的范围和取舍

### 2.1 主线平台

- QEMU AArch64；
- AxVisor；
- Linux Guest：运行模型推理和控制应用；
- Zephyr Guest：运行虚拟对象、传感器和执行器；
- 沿用 Task-2 的 UDP/IP 链路：
  - Linux：`10.0.42.15:4242`；
  - Zephyr：`10.0.42.2:4242`。

### 2.2 当前阶段明确不做

- 不依赖 Task-1 PR 或任何实时性改造；
- 不等待真实开发板；
- 不新增 `TELEMETRY` 消息类型；
- 不把高频传感器流接入可靠 stop-and-wait 通道；
- 不使用 ONNX Runtime、TFLite、GRU/LSTM、YOLO 或 NPU；
- 不做在线训练；
- 不做多对象、多 RTOS 或多板卡扩展；
- 不构建通用控制框架。

如果 MVP 闭环已经稳定，才考虑把周期状态流从 STATUS 拆成独立的、可丢失的
`TELEMETRY` 消息。该扩展不是本阶段的完成条件。

### 2.3 为什么 MVP 复用 STATUS

当前 T2N1 的 `CONTROL` 和 `STATUS` 是可靠消息，每个方向最多有一个等待 ACK 的
帧。MVP 将控制周期限制在 5–10 Hz，并采用请求—响应模式：一条 CONTROL 对应一条
STATUS，不形成高频遥测流，因此不需要修改协议状态机。

Task-3 模式下的业务语义为：

| 消息 | MVP 语义 |
|---|---|
| `CONTROL.value` | Linux 计算出的有界执行器输出 |
| `STATUS.value` | Zephyr 虚拟对象当前状态/传感器读数 |
| `STATUS.last_control_request` | 已应用的控制请求编号 |
| `ACK` | 对可靠 CONTROL/STATUS 的确认 |
| `HEARTBEAT` | 端点存活检测 |

现有 Task-2 默认模式继续保留原行为；Task-3 行为通过独立配置或编译模式启用，
避免破坏已完成的 Task-2 证据。

## 3. 最终应用场景

采用一个带有非线性损耗和负载变化的虚拟温度对象。它比单纯的一阶线性公式更能
说明历史窗口和模型推理的价值，但实现仍然很小。

对象状态范围为 `0..1000`，执行器输出范围也为 `0..1000`。每个控制周期更新一次：

```text
loss(state) = base_loss + nonlinear_loss × state² / 1_000_000
state_next = clamp(
    state + response × (output - state) - loss(state) + disturbance,
    0,
    1000
)
```

固定目标轨迹：

```text
0–5 s：    target = 300
5–15 s：   target = 800
15–25 s：  target = 500
```

固定扰动轨迹：

```text
8 s：      增加一次负载扰动
17 s：     减少一次负载扰动
```

所有参数、扰动和初始状态写入配置，必要时使用固定 seed。正式比较前冻结这些
输入，不能看完 AI 结果再修改场景。

### 3.1 输入来源

Zephyr 在 Guest 内生成虚拟对象状态并把它作为传感器读数返回。Linux 只看到经过
virtio-net、UDP/IP 和 T2N1 的 STATUS，不直接读取 Zephyr 的内部状态。

这满足“AI 输入—模型推理—跨 Guest 网络—RTOS 执行”的边界；输入不需要来自
真实 ADC、摄像头或开发板。

## 4. 模型设计

### 4.1 推荐模型

使用一个中等规模的纯 Rust 1D 时序 CNN，避免“只有几个参数的玩具 MLP”，也避免
引入大型推理运行时：

```text
输入：64 个历史采样点 × 4 个特征
      [state, target, error, previous_output]

Conv1D: 4 → 32，kernel=5，ReLU
Conv1D: 32 → 64，kernel=5，ReLU
Global Average Pooling
Dense: 64 → 32，ReLU
Dense: 32 → 1
```

模型规模控制在约几万参数；Linux Guest 每 100–200 ms 推理一次，QEMU CPU 可以承受。
模型输出为有界控制值，最终仍由 Linux 和 Zephyr 双重限幅。

如果 1D CNN 在实现初期阻塞超过一个工作日，降级为输入相同、隐藏层为 `32 → 32`
的时序 MLP；降级不改变协议和验收流程。

### 4.2 训练与推理边界

- 宿主机离线生成虚拟轨迹并训练模型；
- Linux Guest 只加载固定权重并执行前向推理；
- 权重、归一化参数和模型结构必须有哈希；
- 不在 Guest 内安装 Python 或执行训练；
- 推理核心使用纯 Rust，加入少量 golden-vector 测试。

模型的价值不以参数量单独证明，而以以下证据证明：

1. 输入包含一段历史，而不是单个常数；
2. 对象存在工作区间变化和负载扰动；
3. 模型输出真实进入 CONTROL；
4. AI 与最佳固定参数控制器有可复算对比。

## 5. 控制器和 baseline

### 5.1 固定参数 baseline

Linux 的 baseline 使用固定比例控制：

```text
error = target - state
output = clamp(Kp × error + bias, 0, 1000)
```

`Kp` 和 `bias` 在训练/调参场景上选择并冻结。不能故意使用明显不合理的参数来
制造 AI 优势。

### 5.2 AI 模式

AI 模式使用模型直接输出控制量：

```text
output = clamp(model(history), 0, 1000)
```

Zephyr 仍执行最终安全检查：

- 控制值必须在 `0..1000`；
- 超时或重传耗尽时输出置零或进入 Safe；
- 非法参数不更新对象；
- AI 模式和 baseline 模式使用同一虚拟对象。

这版先不增加 `SetCorrection` 等新 ControlAction，避免把模型语义问题扩大成协议
重构。模型输出、CONTROL 值和 STATUS 的 request ID 通过日志关联，足以证明推理
结果参与了控制。

## 6. 分阶段 TODO

### M0：建立 Task-3 分支和最小记录

- [x] 从 `openrace/task2-net-clean` 创建 Task-3 工作分支；
- [x] 不合并 Task-1 PR，不修改 Task-1 代码；
- [x] 记录当前 Task-2 commit、QEMU 版本、Guest 镜像哈希；
- [x] 创建 Task-3 配置和日志目录；
- [x] 固定场景参数、目标轨迹、扰动和运行时长。

完成标准：Task-2 分支可独立回归，Task-3 有单独配置入口。

M0 基线快照（2026-08-11）：

- Task-2 基线 commit：`01f77307e fix(task2-net): report failures and mark QEMU results`
- Task-3 分支：`openrace/task3-ai-control`
- QEMU：`qemu-system-aarch64` 10.2.1（`~/.local/bin/qemu-system-aarch64`）
- Rust：`rustc 1.99.0-nightly (da80ed070 2026-07-14)`
- Python：3.12.3（numpy 2.5.2，宿主机训练用）
- Zephyr：4.4，board `qemu_cortex_a53`（`/tmp/zephyrproject/zephyr`）
- Zephyr SDK：`/tmp/zephyr-sdk`
- Linux Guest 基础 initramfs：`/home/huhu/tgoskits-realtime/tmp/initramfs-custom`
- 拓扑与 IP（沿用 Task-2）：Linux `10.0.42.15:4242` ↔ Zephyr `10.0.42.2:4242`，
  VirtIO-MMIO 端点 `a003e00`(SPI 47)/`a003c00`(SPI 46)

固定场景参数（MVP）：

```text
state 范围     0..1000
output 范围    0..1000
base_loss      15
nonlinear_loss 120
response       0.35
目标轨迹       0-5s: 300, 5-15s: 800, 15-25s: 500
扰动轨迹       8s: +150 负载, 17s: -150 负载
控制周期       5-10 Hz（请求-响应，一条 CONTROL 对应一条 STATUS）
运行时长       每轮 >= 30s，至少 3 轮配对实验
```

### M1：Zephyr 虚拟对象和状态回传

- [x] 增加 `state`、`target`、`output` 和扰动状态；
- [x] 实现一次 CONTROL 对应一次 plant 更新；
- [x] 将 STATUS.value 改为实际对象状态；
- [x] 保留 STATUS.last_control_request；
- [x] 增加日志：
  - `TASK3_CONTROL_APPLIED`；
  - `TASK2_STATUS_SENT`（沿用 Task-2 标记，未新增 TASK3 前缀版本）；
  - `TASK3_PLANT_STATE`；
- [x] Linux 暂时使用固定值或固定 Kp 发送 CONTROL。

验收：连续完成至少 100 次 CONTROL→STATUS；STATUS.value 不再恒等于 CONTROL.value；
对象状态随目标值变化。

M1 证据（2026-08-11，commit `6e8d6f3ce` + M2 验证轮次）：

- Zephyr 侧 `TASK3_CONTROL_APPLIED` / `TASK3_PLANT_STATE` / `TASK3_DISTURBANCE`
  标记存在；8s/17s 负载扰动按场景触发；
- 单轮 1173 个 CONTROL→STATUS 周期（见 M2 记录），无协议错误；
- STATUS.value 与 CONTROL.value 不同（例：CONTROL=0 → plant 170；CONTROL=236 →
  181），对象状态随目标值 300/800/500 分段变化。

### M2：Linux 控制循环和 baseline

- [x] 删除启动时只发送一次固定 CONTROL 的逻辑；
- [x] 收到 STATUS 后维护历史窗口；
- [x] 实现 baseline 控制器；
- [x] 每次可靠事务完成后才发送下一条 CONTROL；
- [x] 增加 sample/request ID；
- [x] 输出结构化控制日志；
- [x] 连续运行 30 秒并保存 CSV。

验收：baseline 能稳定跟踪目标；没有意外 `TASK2_SAFE`、协议错误或发送错误。

M2 证据（2026-08-11，commit `907922205` + `2758972c8` 后续修订）：

- 运行日志：`results/task3/`（基线 CSV 与指标汇总，见 M4 章节）；
- 单轮运行 104.3 s、1173 个控制周期（>100 周期、>30 s）；
- `TASK2_SAFE` / `TASK2_PROTOCOL_ERROR` / `TASK2_ERROR` 计数为 0；
- 控制周期 100 ms（5-10 Hz 规格内），RTT 均值 ~89 ms；
- baseline 各段稳态：t300→~182、t800（带扰动）→~630、t500→~290，
  存在由非线性损耗引起的稳态误差，作为 AI 对比的诚实基线。

### M3：离线模型和 Linux 推理

- [x] 编写宿主机数据生成脚本；
- [x] 生成多组目标/扰动轨迹；
- [x] 训练 1D CNN；
- [x] 导出固定权重和归一化参数；
- [x] 编写纯 Rust 前向推理模块；
- [x] 添加 Python/Rust golden-vector 对照；
- [x] 记录模型参数量、MAC 估算、权重哈希；
- [x] 在 Linux Guest 内记录推理耗时和模型输出；
- [x] 用模型输出生成下一条 CONTROL。

验收：Linux Guest 日志中存在真实推理记录；同一输入得到稳定输出；模型输出变化
会导致后续 CONTROL.value 变化。

M3 证据（2026-08-11，AI 实验 `ai-run2`）：

- `TASK3_INFER` 日志：378 条真实推理记录（Linux Guest 内执行），
  单次推理 9-12 ms（TCG 环境），模型输出进入 CONTROL.value；
- 模型：13,089 参数，~70 万 MACs/推理，`weights.bin` SHA-256 记录于
  `components/task3-model/model/model.json`；
- golden-vector 与 golden-window 测试（torch f64 参考）全部通过；
- 固定场景闭环模拟 RMSE 33.1；真实双 Guest 运行 RMSE 29.3（vs baseline 191）。

M3 实现说明（2026-08-11）：

- 数据：400 个随机 episode（随机目标阶梯/扰动/初值，30s@100ms），94,800 样本；
  冻结的固定测试场景不进入训练集；
- 标签：残差监督——模型学习 teacher 跟踪策略（gain=0.5 逆控制）与冻结 P 控制器
  的差值（损耗/扰动补偿项），P 项保证闭环稳定；
- 训练：torch（CPU）浮点训练 + 6 轮 DAgger 闭环数据聚合（每轮 120 个随机
  episode 真闭环 rollout、teacher 打标、3 倍重采样），固定 seed；
- 特征契约统一：`scripts/task3/features.py::build_window` 是唯一实现，
  数据集/DAgger/评估/Rust guest（`task3_model::build_features`）全部复用，
  并由 golden-window 测试跨语言锁定；
- Rust 推理：`components/task3-model`，no_std、无分配、f64，权重以
  `model/weights.bin`（LE f64 大端序排列）嵌入；golden-vector 测试 3 例
  （全 0/常数/斜坡）与 torch f64 参考对照，误差 < 1e-9。

### M4：AI/baseline 对比

- [x] baseline 和 AI 使用完全相同的目标轨迹；
- [x] baseline 和 AI 使用完全相同的扰动；
- [x] 至少运行 3 组匹配实验；
- [x] 每组运行至少 30 秒；
- [x] 统计 RMSE；
- [x] 统计调节时间；
- [x] 统计最大超调；
- [x] 统计推理时间和 CONTROL→STATUS 延迟；
- [x] 生成一张汇总表和两条响应曲线。

首要指标为 RMSE 和调节时间；AI 不需要在所有指标和所有场景中都获胜，但结果
必须诚实报告，不能使用故意调差的 baseline。

M4 证据（2026-08-11，QEMU 双 Guest，6 组 × ~39 s 闭环）：

| 指标 | AI (n=3) | baseline (n=3) |
|---|---|---|
| 整体 RMSE | 29.2 / 29.3 / 29.3 | 191.3 / 190.6 / 190.7 |
| t300 段 RMSE（0-5s） | 49.1 | 102.9 |
| t800 段 RMSE（5-15s） | 40.8 | 217.0-219.3 |
| t500 段 RMSE（15-25s） | 21.6 | 192.2 |
| t500 调节时间 | ~0.8 s | 未收敛（稳态误差 ~192） |
| 稳态误差（t500 段） | ~2（498 vs 500） | ~192（308 vs 500） |
| 推理耗时（Guest 内） | 均值 11.3 ms，p95 14.6 ms | - |
| CONTROL→STATUS RTT | ~104 ms | ~91 ms |

原始数据：`results/task3/run-{1..6}.csv`、`summary.csv`、`comparison.png`。
说明：t800 目标 800 超过 plant 可持续上限（~760，含扰动 ~880），AI 以 ~790-810
逼近；baseline 因无前馈停留在 ~620。t300/t800 调节时间在 5% 带内未完全收敛，
如实留空。

### M5：一次故障闭环

- [ ] 运行 AI 控制时通过 QMP 执行 link down；
- [ ] 验证 heartbeat timeout 或重传耗尽可观察；
- [ ] Zephyr 输出进入 Safe 或安全默认值；
- [ ] link up 后观察恢复事件；
- [ ] 至少保存一份 AxVisor 日志和两侧 pcap；
- [ ] 不要求此阶段重新实现 ACK-drop proxy，Task-2 已有证据可以引用。

验收：故障期间对象不出现无界发散；恢复行为有明确日志。

### M6：收口和视频

- [ ] 编写 Task-3 设计文档；
- [ ] 写明 SIL 边界，不声称真实板卡或硬实时保证；
- [ ] 保存模型结构、权重哈希和推理测试向量；
- [ ] 保存 baseline/AI 原始 CSV、日志和指标结果；
- [ ] 保存完整 QEMU 构建/运行命令；
- [ ] 录制双 Guest 启动、模型推理、CONTROL/STATUS、对象变化和故障处理；
- [ ] 单独提交 Task-3 PR；
- [ ] 运行 Task-2 回归和 Task-3 验收。

## 7. 证据格式

建议每条控制周期都能关联：

```text
sample_id
target
state_before
model_output
control_value
state_after
infer_us
control_rtt_us
mode
```

推荐日志标记：

```text
TASK3_INFER sample=... output=... infer_us=...
TASK3_CONTROL_SENT request=... value=...
TASK3_CONTROL_APPLIED request=... value=...
TASK3_STATUS_RECEIVED request=... value=...
TASK3_PLANT_STATE target=... state=...
```

最终运行记录应包含：

- Git commit；
- 工作区 dirty 状态；
- QEMU、Rust 和 Guest 镜像版本；
- 模型权重哈希；
- 目标轨迹和扰动参数；
- 原始日志/CSV/pcap 哈希；
- 指标统计命令。

## 8. 真实板卡迁移边界

当前不要求板卡。QEMU 虚拟对象作为正式 SIL 验收路径，足以证明任务三的网络和
应用闭环。

将来迁移板卡时只替换 Zephyr 内部的两类实现：

```text
virtual_sensor  → ADC/GPIO/真实传感器
virtual_actuator → PWM/LED/电机/真实执行器
```

Linux 模型、T2N1 网络协议和控制日志格式不应随之改变。

## 9. 停止规则

- 如果 M1 不能完成，不开始模型工作；
- 如果 M2 的 baseline 不能稳定运行，不增加 CNN；
- 如果 CNN 手写推理超过一个工作日仍未通过 golden-vector，降级为 32→32 时序 MLP；
- 如果指标脚本不能从原始日志重算，不录制最终视频；
- 不因为模型参数量继续扩展网络，不引入与任务三评分无关的通用框架；
- Task-1 不作为 Task-3 前置条件，不等待 PR #1934。

## 10. 完成定义

以下条件全部满足时，Task-3 MVP 即可交付：

- [ ] QEMU 中 Linux/Zephyr 双 Guest 可复现启动；
- [ ] Zephyr 有非恒定的虚拟传感器/对象状态；
- [ ] Linux Guest 内真实执行 1D CNN 推理；
- [ ] 推理输出真实进入 T2N1 CONTROL；
- [ ] Zephyr 应用控制并回传 STATUS；
- [ ] baseline 和 AI 均完成至少 100 个控制周期；
- [ ] 有 RMSE、调节时间和延迟数据；
- [ ] 有一次 link down/up 安全行为证据；
- [ ] 有原始日志、CSV、模型哈希和复现命令；
- [ ] 有可展示完整闭环的演示视频；
- [ ] Task-2 原有测试和证据不回归。
