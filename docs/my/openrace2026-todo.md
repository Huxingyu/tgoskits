# OpenRace 2026 工控虚拟化赛题 TODO

> 初版日期：2026-07-25；十天冲刺更新：2026-07-31
> 对应仓库：`/Users/huxingyu/project/tgoskits`
> 基线提交：`759e69c`
> 攻关截止：2026-08-20；成果提交：2026-08-21 至 2026-08-24
> v7：增加 Day1–Day7 实际进度校准；Day5 优先补齐干净 Linux 启动和 stress 证据，再进入实时改造与 A/B。
> v8（2026-08-08）：冻结 `passthrough` 为当前 QEMU 主线；`emulated` 的 PPI27 失败保留为已知限制；物理板卡仍需独立验证。
> v9（2026-08-08）：冻结 AArch64 lower-EL IRQ 的最小改造为“单次 host IRQ 事务”；`passthrough` 仍是当前 QEMU 主线，emulated PPI27 仍保留为已知限制。
> v10（2026-08-08）：根据任务一严格验收审计，撤销“已完成实时改造”的含义；当前只认定为“启动/基线前置证据完成，改造和验收证据未完成”。

---

## 1. 范围与推进原则

官网依据：<https://opencamp.cn/qcl/camp/OpenRace2026/stage/1>。

官网明确要求：

- 任务一：实质改造 Axvisor 的实时关键路径，启动不少于 2 个 vCPU 的 Linux Guest，完成改造前后、空载/压力及原生 RTOS 基线对比。
- 任务二：在 Linux/Starry Guest 与 RTOS Guest 之间建立双向 IP 网络，实现应用协议、控制/状态/错误消息、可靠性和量化测试。
- 任务三：在 Linux/Starry Guest 中运行神经网络，通过任务二协议驱动 RTOS，形成可观察闭环，并与固定参数方案比较至少两项指标。
- 提交设计文档、测试文档、源码 PR、复现说明和约 5 分钟演示视频；视频展示双终端、通信数据流动和 AI—控制联动。

以下属于团队实现选择，不得写成官网硬要求：

- 两个 Guest 位于同一个 Axvisor 实例；
- 固定使用 4 个 pCPU；
- 双 Guest 连续运行 30 分钟；
- 网络数据面必须由 Axvisor 内部 vSwitch 提供。

推进规则：

1. 主线只使用 Linux、一个 RTOS、QEMU aarch64 和 CPU 小模型。
2. StarryOS、更多 RTOS/板卡、NPU 和内部 vSwitch 不得阻塞主线。
3. 每项实验至少保存命令、commit、平台/镜像信息、原始数据和摘要；不建设独立的通用验证框架。
4. 性能阈值在第一次正式基线后冻结，不能看完优化结果再放宽。
5. 每个里程碑只以本节列出的完成门槛为准，不再维护重复的逐项验证矩阵。

### 当前模式决策与术语边界（2026-08-08）

- 在本项目语境中，**Host** 指运行在 QEMU/物理板卡上的 Axvisor 及其 ArceOS/platform 运行环境；Linux 和 Zephyr 是 Guest，pCPU 属于 Host，vCPU 属于 Guest。
- 同一个 VM 的 `interrupt_mode` 是三选一枚举（`no_irq`、`emulated`、`passthrough`），其中 `emulated` 与 `passthrough` 不能同时启用；不同 VM 可以分别选择不同模式。
- `interrupt_mode` 与 `passthrough_devices`/`emu_devices` 不是同一个开关：前者选择中断后端，后两者选择具体设备资源。当前 AArch64 旧实现中，`passthrough` 同时打开 vCPU 的 interrupt/timer passthrough 设置，但不表示 IRQ 完全绕过 Axvisor。
- 当前主线固定为 `interrupt_mode = "passthrough"`：QEMU 上已有 Linux 2-vCPU、Zephyr 周期任务、双 Guest 和 0 DMA quarantine 证据。`emulated` 仅作为探针，不作为任务一改造或最终演示的前置条件。
- 任务二和任务三不要求 `emulated`：网络链路可使用 virtio/tap、桥接或合适的网卡直通，AI 控制闭环运行在 Guest 用户空间；但板卡上的网卡 DMA、IRQ 所有权和双 Guest 拓扑必须单独验证。
- 物理板卡沿用该路线在架构上可行，但 QEMU 证据不能替代板测；上板前必须核对 GIC/timer FDT、pCPU 绑定、MMIO/IRQ/DMA 所有权和网卡拓扑。

---

## 2. 评分映射

| 官网评分项 | 分值 | 对应里程碑 |
|---|---:|---|
| 实时 RTOS 化改造 | 30 | M1、M3、M5 |
| 基于网络的客户机间通信 | 25 | M2、M5 |
| AI 控制闭环演示 | 25 | M4、M5 |
| 工程完整性与文档 | 15 | 全程留证，M5 汇总 |
| 系统创新与扩展性 | 5 | 主线改造质量；不单独造大功能 |
| StarryOS/更多基线加分 | 最多 10 | M6，可选 |

---

## 3. 主线系统

推荐使用同一个 Axvisor 实例完成最终演示，这是争议最小的实现，但属于团队选择：

```text
QEMU aarch64
└── Axvisor
    ├── Linux Guest：2 vCPU，运行神经网络
    └── RTOS Guest：1 vCPU，运行周期控制

RTOS ── SENSOR ──UDP/IP──► Linux AI
RTOS ◄─ CONTROL/STATUS ─── Linux AI
```

推荐 4 核布局：

| pCPU | 用途 |
|---|---|
| 0 | Axvisor 管理、串口和非实时后台任务 |
| 1–2 | Linux 的两个 vCPU |
| 3 | RTOS vCPU |

推荐网络：

- Linux：`10.42.0.2/24`
- RTOS：`10.42.0.3/24`
- 两张独立 virtio-net 设备直通给两个 Guest，并连接同一 QEMU hub/tap
- 官网明确允许虚拟网卡、桥接和用户态网络，主线不实现内部 vSwitch

---

## 4. 里程碑

| 里程碑 | 目标日期 | 工作量 | 完成门槛 |
|---|---:|---:|---|
| M0：方案冻结 | 7 月 25 日 | 0.5–1 人日 | 平台、RTOS、场景、指标和证据格式确定 |
| M1：启动与实时基线 | 7 月 29 日 | 3–4 人日 | Linux 2 vCPU、RTOS 基线和双 Guest 冒烟通过 |
| M2：IP 通信 | 8 月 2 日 | 3–4 人日 | 控制/状态/错误消息及故障恢复通过 |
| M3：Axvisor 实时改造 | 8 月 8 日 | 5–7 人日 | 至少一个关键机制有实质改造并体现收益 |
| M4：AI 控制闭环 | 8 月 13 日 | 4–5 人日 | 神经网络输出被 RTOS 实际应用并完成两项指标对比 |
| M5：总体验收与提交 | 8 月 20 日 | 3–4 人日 | 数据、文档、PR、复现和视频齐全 |
| M6：加分项 | 剩余时间 | 可选 | 主线完成后独立选择 |

### 4.1 十天五阶段冲刺（2026-07-31 至 2026-08-09）

目标是在十天内完成“可运行、可测量、可演示、可提交”的主线 MVP。每天按 6–8 小时有效开发时间安排；8 月 10 日至 20 日保留为修复、复测和提交缓冲期。

#### 阶段 1/5：运行基线（7 月 31 日至 8 月 1 日）

**第 1 天**

- [ ] 安装 QEMU，完成仓库固定 Rust nightly 工具链。
- [ ] 新增 QEMU AArch64 Linux 2 vCPU 配置。
- [ ] 交叉编译 Axvisor，并启动 Linux Guest。
- [ ] 在 Guest 内用 `nproc` 和 `/proc/cpuinfo` 确认两个 vCPU。

**第 2 天**

- [ ] 选定并启动 FreeRTOS 或 Zephyr Guest。
- [ ] 完成 Linux 与 RTOS 双 Guest 最小启动验证。
- [ ] 建立统一延迟日志格式和统计脚本。
- [ ] 记录 CPU、内存、设备、中断和镜像信息。

**完成门槛：** Linux 2 vCPU 和 RTOS 有启动证据，双 Guest 能同时在线，基线数据可由脚本统计。  
**累计完成度：约 15%。**

#### 阶段 2/5：完成任务一（8 月 2 日至 8 月 3 日）

**第 3 天**

- [ ] 运行 idle 和 Linux stress 两组未改造基线。
- [ ] 采集 jitter、mean、p99、max 和超期次数。
- [ ] 区分调度、定时器、中断注入和日志干扰。
- [ ] 根据数据冻结一个主要优化点和回滚方式。

**第 4 天**

- [ ] 实现一项 Axvisor 实时关键路径改造。
- [ ] 添加能覆盖该改造的确定性回归测试。
- [ ] 使用相同环境完成改造前后 A/B 测试。
- [ ] 运行格式化、修改 crate 的 clippy 和相关回归。

**完成门槛：** 至少一个关键机制有实质代码变化，并有同口径改造前后数据。  
**累计完成度：约 35%。**

#### 阶段 3/5：完成任务二（8 月 4 日至 8 月 5 日）

**第 5 天**

- [ ] 打通 Linux 与 RTOS 的双向 UDP/IP 链路。
- [ ] 固定 MAC、IP、端口、IRQ 和网络拓扑。
- [ ] 实现协议头及 `CONTROL`、`STATUS`、`ERROR` 消息。
- [ ] 保存两侧日志和可识别为 UDP/IP 的抓包。

**第 6 天**

- [ ] 实现 ACK、超时、有限重传和重复包处理。
- [ ] 注入丢包、短暂断网和重复/乱序报文。
- [ ] 统计成功率、RTT、超时、恢复时间和有效吞吐。
- [ ] 固化自动化通信测试命令。

**完成门槛：** Linux 与 RTOS 能通过 IP 网络完成控制、状态、错误和故障恢复。  
**累计完成度：约 60%。**

> ⚠️ 阶段 3 是最可能超时的部分。第 5 天结束仍未打通网络时，第 6 天停止扩展，只保留最小 UDP `CONTROL/STATUS` 链路。

#### 阶段 4/5：完成任务三（8 月 6 日至 8 月 7 日）

**第 7 天**

- [ ] 准备一个两层小型 MLP 及固定权重。
- [ ] 在 Linux Guest 内运行真实神经网络推理。
- [ ] 将模型输入、输出、归一化和权重哈希写入文档。
- [ ] 通过任务二协议发送有界控制参数。

**第 8 天**

- [ ] RTOS 应用参数并模拟 PWM 或一阶对象控制。
- [ ] 回传实际应用值、状态和错误信息。
- [ ] 测量完整闭环端到端延迟。
- [ ] 比较 AI 与固定参数控制的误差和调节时间。

**完成门槛：** AI 输入、Linux 推理、网络传输、RTOS 控制和状态回传形成可观察闭环。  
**累计完成度：约 82%。**

#### 阶段 5/5：总体验收与交卷（8 月 8 日至 8 月 9 日）

**第 9 天**

- [ ] 运行实时、网络和控制三组完整测试矩阵。
- [ ] 完成长稳与故障恢复测试，保存原始数据。
- [ ] 修复阻塞演示的问题，冻结非必要功能。
- [ ] 运行格式化、clippy、回归和干净工作区检查。

**第 10 天**

- [ ] 完成设计文档、测试报告和复现说明。
- [ ] 整理配置、脚本、图表、已知限制和代码链接。
- [ ] 录制约 5 分钟双终端闭环演示视频。
- [ ] 整理提交记录、PR 标题和中文 PR 描述。

**完成门槛：** 新环境可按文档复现，三个任务均有代码、原始数据和演示证据。  
**累计完成度：100%。**

### 4.2 Day1–Day7 当前进度与重新安排（2026-08-07）

当前有效成果：

- [x] Day1：完成 Rust、QEMU 10.2.1 和 AArch64 环境；验证 Axvisor → ArceOS、Axvisor → Linux shell、QEMU → StarryOS。
- [x] Day2：选定 Zephyr；验证 Linux 2-vCPU、Zephyr 单 Guest 和带 DMA quarantine 告警的双 Guest；建立第一版统计脚本。
- [x] Day3：将设备直通缩小到 UART、GIC 和 timer，实验日志中的 DMA quarantine 降为 0。
- [x] Day4：完成 Zephyr 10 ms、300 样本周期采样器；取得 Native QEMU 和 Axvisor 单 Guest 两组有效基线。

Day3–Day4 尚未解决，并且是 Day5–Day7 的前置条件：

- [x] `MAP_ALLOC` 干净配置下取得 Linux 内核真实启动证据，不能只使用 `VM[1] boot success`；根因是生成 FDT 未注入 `kernel.cmdline`，已补 `/chosen/bootargs`。
- [x] Linux 自身确认两个 CPU，并输出 `SMP: Total of 2 processors activated`；缩小直通设备时补回 `/psci` 节点后通过。
- [x] Linux stress init 输出 `LINUX STRESS START workers=2`，证明两个 worker 实际运行。
- [x] 同一次双 Guest 实验中 Zephyr 输出 `PERIODIC LATENCY COMPLETE samples=300`，且日志无 DMA quarantine 告警。
- [x] 获得可用于结论的 Linux idle/stress CSV，并依据尾延迟排除明显的共享调度竞争；具体改造点仍待覆盖对应路径的实验。

#### Day5：补齐基础证据并冻结改造点

- [x] 修复或解释 `MAP_ALLOC` 下 Linux 没有可观察内核启动的问题。
- [x] 取得 Linux 2-vCPU、stress worker、Zephyr 周期任务和 0 DMA quarantine 的同场日志。
- [x] 采集同配置的 Linux idle 与 stress 短基线，统计 mean、p99、p99.9、max 和 deadline miss。
- [x] 冻结实验模式：任务一主线使用 `passthrough`；不修复 PPI27 也不阻塞任务一，`emulated` 只记录为非主线已知限制。
- [x] 根据数据冻结一个可被当前 workload 覆盖的最小改造点：当前 Zephyr 直通 `/timer` 且独占 pCPU 3，先改造 AArch64 vCPU entry/host-IRQ 边界；不得把结果直接归因于软件 vIRQ 队列或 timer wheel。
- [x] 用本地 emulated-timer 探针覆盖 Guest virtual-timer PPI 27：VM/vCPU 可启动，但 IRQ 27 未匹配宿主 action 并持续重入；直接排队 workaround 复测后因 level/EOI 语义错误回退。该结果冻结了后续改造边界，但不计作已完成改造。
- [x] 检索上游相关记录：PR #1770 和 #1717 已公开处理 AArch64 timer ownership、physical timer 和 EOI 生命周期等同类问题；未找到明确记录 `PPI27`/`hwirq 27` 重复未处理 IRQ 的条目，因此该具体复现标记为当前分支的已知限制。
- [x] 先添加旧实现必然失败的确定性回归测试，并完成第一版最小改造：lower-EL IRQ 在 `gic::fetch_irq` 已完成 claim/dispatch/EOI 后，deferred 阶段只检查 timer，不再重复 dispatch。

**Day5 完成门槛：** Linux 和 stress 有 Guest 内部证据，双 Guest 数据有效，Axvisor 改造对象和回归测试已冻结。未达到门槛时不得把观察 CSV 写成 Linux stress 结论。

**预计累计完成度：65%–75%。**

#### Day6：完成实时改造、A/B 和稳定性测试

- [ ] 完成一个有数据依据的 Axvisor 实时关键路径实质改造。
- [ ] 运行修改 crate 的 `cargo fmt`、目标 clippy 和确定性回归测试。
- [x] 用修改后二进制重跑同一双 Guest `passthrough` stress 配置：Linux 2-vCPU、`LINUX STRESS START workers=2`、Zephyr 300 周期和无 DMA quarantine 均出现；原始日志见 `results/day6/axvisor-dual-stress.log`。
- [ ] 修复双 Guest 交织输出造成的 6 个缺失 CSV 行，补齐 300 样本后再把结果纳入正式 A/B。
- [ ] 使用相同镜像、CPU 绑定、设备配置和 workload 运行改造前后 idle/stress A/B。
- [ ] 对比 Native、改造前和改造后的 p99、p99.9、max 与 deadline miss，不只比较平均值。
- [ ] 最终版本运行 30 分钟，检查 panic、Guest 卡死、DMA quarantine 和周期任务中断。

**Day6 完成门槛：** 代码 diff 能解释改善机制，回归测试通过，至少一个压力场景有可信 A/B 结论，30 分钟运行无阻塞故障。

**原冲刺计划估算：85%–90%；这不是评分完成度。按本次严格审计，任务一仍未通过验收。**

#### Day7：形成任务一交付包

- [ ] 写清实时目标、问题定位、改造机制、替代方案和非目标。
- [ ] 固化 Linux 2-vCPU、CPU 绑定、内存、设备、IRQ、镜像哈希和启动参数。
- [ ] 汇总 Native、改造前后、idle/stress 的原始 CSV、日志、命令和统计表。
- [ ] 记录 QEMU 与真实板卡差异、Zephyr 选择原因、未完成项和结果限制；若声称完成板卡演示，还需补充板卡 GIC/timer FDT、pCPU、MMIO/IRQ/DMA 和网卡验证证据。
- [ ] 对照任务一评分项完成最终检查，运行格式化、clippy、回归测试和工作区检查后提交。

**Day7 完成门槛：** 任务一每个评分点都有代码、命令、原始数据或明确限制说明，新环境可以按文档复现。

### 4.3 任务一严格验收审计（2026-08-08）

#### 审计结论

**没有严格完成任务一。** 当前完成的是 Linux/Zephyr 双 Guest 的启动和短时周期采样前置证据，以及一项带确定性单元回归的 AArch64 host-IRQ 边界修复；尚未完成“AxVisor 实时关键路径实质改造并证明收益”的核心闭环。因此不能按 30 分任务一已交付，也不能把当前结果写成实时性改善结论。

官网页面本轮无法通过网络稳定抓取，下面按仓库保存的赛题整理 [`openrace2026-axvisor-topics.md`](openrace2026-axvisor-topics.md) 和会议纪要 [`meet1.md`](../meeting/meet1.md) 审计；不把未重新核验的网页内容冒充最新官方原文。

#### 逐条对照

| 任务一硬要求 | 当前证据 | 状态 | 尚缺什么 |
|---|---|---|---|
| 分析并优化调度、抢占、定时器、中断、亲和性或锁等关键路径 | 有候选路径分析；完成 lower-EL host IRQ 避免重复 dispatch 的局部修复 | **部分满足** | 没有证明该路径被正式 workload 稳定覆盖，也没有证明最坏延迟改善；`passthrough` 主线可能绕开软件 vIRQ/timer wheel |
| 改造后启动不少于 2-vCPU Linux，并说明 CPU 绑定、内存、设备、IRQ、启动参数 | Day5/Day6 日志出现 Linux 启动、`SMP: ... 2 processors`、stress worker；VM 配置记录 pCPU `[1,2]`、内存、直通设备和 cmdline | **基本满足（短时）** | 没有 10/30 分钟稳定性证据；QEMU 证据不能替代物理板卡证据 |
| 测量周期抖动、调度延迟、中断响应延迟、最大延迟和长稳 | 有 10 ms/300 样本 jitter CSV、mean/p99/p99.9/max | **部分满足** | 尚无调度延迟和中断响应延迟指标；无 30 分钟/1 小时长稳数据；改造后二进制 CSV 只有 294 行 |
| 记录命令、运行时长、CPU 负载分布和结果数据 | README 有启动命令、配置和原始日志；有 idle/stress 场景 | **部分满足** | 当前只是约 300 个周期的短探针，不是正式长时测试；改造前后尚无同口径完整矩阵和可复算汇总 |
| 以原生 Zephyr/其他原生 RTOS 作等价周期任务和压力基线，并解释差异 | 有 Native QEMU Zephyr 与 AxVisor 单 Guest 基线；README 解释了直通 timer/pCPU 限制 | **部分满足** | 尚无 Native、未改造 Axvisor、改造后 Axvisor 三方在相同 workload 下的正式对照 |
| 提供代码、镜像、配置、构建/启动命令、脚本、RTOS 配置和可复现实验 | 已有局部代码、VM 配置、脚本、日志、CSV 和哈希 | **部分满足** | 任务一最终设计/测试报告、完整复现包、PR 和演示材料尚未收口 |

#### 六个评分点的当前判定

| 评分点 | 当前判定 |
|---|---|
| 实时化目标和关键路径分析清楚（4） | 有初步分析和非目标，但仍需把“实际覆盖路径”和成功指标写实 |
| 调度/抢占/定时器/中断/锁的实质改造（8） | 有代码变化和回归测试，**尚不能按已满足计分**；需证明它是实际实时关键路径且不只是重复 dispatch 修复 |
| 多核 Linux 稳定启动（4） | 启动和 2-vCPU 证据基本具备；稳定性尚未完成 |
| 改造前后最坏延迟/抖动改善（5） | **未满足**：没有完整 A/B，改造后缺 6 个样本，不能下改善结论 |
| 空载与 stress 对比（4） | 改造前有；改造后不完整，**未满足完整评分证据** |
| 原生 RTOS 基线对比（5） | 有初始 Native 基线；尚未完成三方统一口径对比 |

#### 必须纠正的指标口径

`deadline_misses=300` 并不等于 300 次实时失败。当前采样器把 `actual_ns` 与绝对 release deadline 比较，而每个样本的 `jitter_ns` 本身按正 lateness 记录，所以该字段在现有数据中必然为全量超期。它可以保留作原始字段，但在正式报告中必须改名或明确解释，并新增真正的 deadline/period overrun 定义，不能把它当作改造收益指标。

#### 重新开放的任务一 Gate

在以下证据完成前，不得把任务一标记为完成或宣称实时性改善：

1. 先确认正式 workload 是否覆盖 Axvisor 软件 vIRQ/timer/host-IRQ 路径；若 `passthrough` 不覆盖，必须补等价的 `emulated` 或明确可观测的路径实验，不能用旁路路径证明改造收益。
2. 重新构建未改造版和改造版，固定镜像、QEMU、pCPU、内存、设备、IRQ 和 workload，完成 Native / 未改造 / 改造后三方的 idle + stress A/B。
3. 两个版本都补齐 300/300 样本，并报告周期 jitter、调度延迟、中断响应延迟、p99.9、max 和清晰定义的 overrun/deadline miss。
4. 至少完成一次 30 分钟（最终内部 Gate 为 1 小时）稳定性运行，保存原始日志并检查 panic、Guest 卡死、IRQ 重入、DMA quarantine 和串口丢失。
5. 再整理任务一设计说明、替代方案/非目标、复现命令和评分点证据表；在此之前只报告“部分完成”。

---

## 5. M0：方案冻结

- [ ] **M0-01 固定平台和软件版本**
  - QEMU aarch64、Linux、一个目标 RTOS、项目钉死的 Rust nightly。
  - 记录 Rust/Cargo/QEMU 版本、Guest 镜像来源和哈希。

- [ ] **M0-02 固定最小演示场景**
  - 使用确定性的一阶对象或等价轻量控制对象。
  - 固定参数控制作为基线；小型 MLP 根据传感器窗口选择或调整一组有界控制参数。
  - 非目标：真实电机、NPU、复杂视觉模型、通用控制框架。

- [ ] **M0-03 固定指标和实验记录格式**
  - 实时：周期抖动、调度延迟、中断响应延迟、max；补充 p99/p99.9 便于分析。
  - 网络：成功率、应用错误、超时、恢复时间、RTT、有效吞吐。
  - 控制：从控制误差、超调、调节时间、端到端延迟中选择至少两项。
  - 每次实验保存：commit、dirty 状态、命令、平台、CPU/Guest 布局、镜像/模型哈希、运行时长、负载和原始 CSV/日志/pcap。

- [ ] **M0-04 保存官网依据并发出一个可选确认**
  - 保存官网正文或哈希、抓取日期和页面地址。
  - 可询问：两个 Guest 是否必须属于同一 Axvisor 实例，以及双 NIC 直通加 QEMU bridge/hub 是否完整计入任务二。
  - 未回复不阻塞主线；官网已允许虚拟网卡、桥接和用户态网络。

### M0 完成门槛

- 平台、RTOS、控制场景和两项控制指标已经冻结。
- 所有人使用同一份命令、镜像和结果目录约定。

---

## 6. M1：启动、双 Guest 冒烟与原始基线

- [ ] **M1-01 启动 Linux 2-vCPU Guest**
  - 配置 `cpu_num = 2`，记录 vCPU/pCPU 绑定、内存、设备、中断和启动参数。
  - Linux 内 `nproc` 和 `/proc/cpuinfo` 显示两个 CPU。

- [ ] **M1-02 选定并启动一个 RTOS**
  - 先判断 RT-Thread 的 QEMU/virtio-net 能力；两人日内不能形成可验证路径就切换候选 RTOS。
  - 实现与原生/裸机基线一致的周期任务，输出序号和 deadline jitter。
  - ArceOS 只可用于定位 Axvisor 双 Guest/设备问题，不能作为最终 RTOS。

- [ ] **M1-03 完成双 Guest 最小冒烟**
  - 为两个 VM 分配不重叠的 VM ID、vCPU、内存、GIC/IRQ 和设备。
  - 不复制两份 `passthrough_devices = [["/"]]`；必须显式划分资源。
  - 两路输出能够分别观察；可以使用 PL011、最小 TX 日志、HVC 或网络终端，不要求先实现完整串口模拟。
  - 先运行 10 分钟无 panic、卡死和 heartbeat 中断；30 分钟留到 M5 稳定性测试。

- [ ] **M1-04 采集未改造 Axvisor 与原生 RTOS 基线**
  - 使用相同或等价周期任务，记录平台差异。
  - Axvisor 场景由 RTOS Guest 运行周期任务，Linux 2-vCPU Guest 提供空载或 stress 环境。
  - 至少包含空载和 Linux stress 两种场景。
  - 输出周期抖动、调度延迟、中断响应延迟和最大延迟原始数据。

### M1 完成门槛

- Linux 2 vCPU 的配置和启动证据完整。
- 原生 RTOS 与未改造 Axvisor 的同类 workload 数据可比较。
- 两个 Guest 可同时在线并分别观察，为任务二、三提供运行基础。

---

## 7. M2：客户机间 IP 通信

- [ ] **M2-01 建立双 Guest IP 链路**
  - 为两个 Guest 分配独立 virtio-net 设备、MAC、IP、IRQ 和后端。
  - 先用 ArceOS 隔离验证 Axvisor 直通/vIRQ 问题，再替换为目标 RTOS。
  - Linux 与 RTOS 能互相 ping，并能双向收发 UDP。

- [ ] **M2-02 定义最小应用协议**
  - 固定一个小端无关的 wire format，至少包含官网要求的 version、type、length、sequence/timestamp、status/error。
  - 主消息只保留：`SENSOR`、`CONTROL`、`STATUS`、`ERROR`、`ACK`、`HEARTBEAT`。
  - 提供 Linux/RTOS 共用的 golden bytes；未知版本、错误长度和未知类型必须拒绝。

- [ ] **M2-03 实现 UDP 最小可靠性**
  - 对 CONTROL/STATUS 使用 ACK、超时和有限重传。
  - sequence 用于重复去除和乱序拒绝；重复 CONTROL 不得重复应用。
  - heartbeat 超时后 RTOS 进入安全模式，恢复后重新建立会话。
  - 不在主线实现滑动窗口、通用 RPC 或额外 TCP 管理通道。

- [ ] **M2-04 实现控制、状态和错误三类业务**
  - Linux 发送控制参数。
  - RTOS 返回实际应用值或拒绝原因，不能只返回“已收到”。
  - 非法参数、版本错误和超时均产生可观察错误或安全降级。

- [ ] **M2-05 自动化通信测试**
  - 清洁网络下运行固定报文数或固定时长，统计成功率、RTT、吞吐和应用错误。
  - 至少注入一种丢包比例、一次短暂断网和一次重复/乱序。
  - 保存 pcap、两侧日志和机器可读摘要。

### M2 完成门槛

- 主通道能被抓包识别为 UDP/IP，不使用 IVC、HyperCall、裸 MMIO 或 vsock 传递业务载荷。
- 控制、状态、错误、超时、重试和恢复均有自动化证据。
- 官网允许的双 NIC 直通方案可直接验收；只有明确否定答复才考虑其他数据面。

---

## 8. M3：Axvisor 实时改造

本里程碑不预设必须实现完整 `sched-rt`。先依据 M1 数据选择能直接影响最坏情况延迟的改造，避免同时铺开调度、tick、IRQ、锁和观测系统。

- [ ] **M3-01 用基线定位一个主问题**
  - 区分两种实验：独占 pCPU 场景用于 IRQ/timer/vIRQ 路径；共享 pCPU 压力场景用于调度/抢占。
  - 如果 RTOS 独占 pCPU，不得用“RTOS 抢占 Linux”解释收益。
  - 记录候选方案、预期收益、风险、回滚方式和验证 workload。

- [ ] **M3-02 实现一个主实时改造**
  - 路线 A：若共享核心调度竞争是主要问题，实现固定优先级和唤醒抢占。
  - 路线 B：若尾延迟来自中断路径，优先改造 vIRQ 有界预分配队列、IRQ affinity、tick 或关键日志路径。
  - 至少有一个 Axvisor 关键机制发生实质代码变化；不能只改配置或打开已有 feature。

- [ ] **M3-03 完成必要的配套调整**
  - 只实现支撑主改造所需的 feature、配置、trace 和错误处理。
  - 不以“顺便完善”为由扩展到无测量依据的子系统。

- [ ] **M3-04 添加确定性回归并完成静态检查**
  - 修复前或错误实现上测试稳定失败，修复后通过。
  - 运行 `cargo fmt` 和所有修改 crate 的 `cargo xtask clippy --package <crate>`。

- [ ] **M3-05 运行改造前后对比**
  - 使用同一 workload、CPU 布局、采样时长和压力配置。
  - 报告空载与 stress 下的 jitter、调度/中断延迟和 max。
  - 说明收益、退化和测量限制，不隐藏不利结果。

### M3 完成门槛

- 至少一个调度、抢占、timer、IRQ 或锁相关关键机制有实质改造。
- 改造前后数据可复算，并对最坏情况延迟或抖动体现可重复改善。
- Linux 2-vCPU Guest 在改造后的 Axvisor 上稳定启动。

---

## 9. M4：AI 控制闭环

- [ ] **M4-01 建立固定参数控制基线**
  - RTOS 维护确定性对象、固定参数控制器、输出限幅和安全状态。
  - 固定 seed 下输入与扰动可复现。

- [ ] **M4-02 准备小型神经网络**
  - 优先使用小型 MLP，根据最近 N 个传感器值选择或调整有界参数。
  - 固定输入在 host 与 Linux Guest 中得到一致结果。
  - 保存模型来源、输入输出、归一化、权重哈希；主线不依赖 NPU。

- [ ] **M4-03 接入任务二协议**
  - RTOS 发送 SENSOR，Linux 推理后发送 CONTROL。
  - RTOS 校验范围、变化率、sequence 和新鲜度后应用参数，并返回 STATUS。
  - 断网、模型退出或非法参数时回退到固定参数控制。

- [ ] **M4-04 测量端到端延迟**
  - 优先使用同一侧时钟测量完整往返，例如 RTOS 从发送 SENSOR 到应用 CONTROL。
  - 只有确需拆分跨 Guest 阶段时才增加时钟同步。

- [ ] **M4-05 公平比较固定控制与 AI 控制**
  - 使用相同 seed、目标和扰动，重复多轮。
  - 至少报告官网要求的两项指标，例如控制误差与调节时间，同时报告端到端延迟。
  - 官网要求是完成两项指标对比，不是“两项必须都改善”；结果必须如实呈现。

- [ ] **M4-06 准备可观察闭环演示**
  - 双终端显示 SENSOR、推理结果、CONTROL、实际应用值、状态回传和故障降级。
  - 5 分钟内完成固定参数、AI 控制和一次故障恢复演示。

### M4 完成门槛

- Linux Guest 中确实执行神经网络推理。
- 模型输出通过任务二网络协议传输，并由 RTOS 实际应用或明确拒绝。
- 闭环包含输入、推理、网络、控制输出和状态回传。
- 固定参数与 AI 方案完成至少两项公平、可复算的指标对比。

---

## 10. M5：总体验收与提交

- [ ] **M5-01 完成任务一实验矩阵**
  - 原生 RTOS、未改造 Axvisor、改造后 Axvisor。
  - 空载与 Linux stress。
  - 至少完成一次 1 小时稳定性运行；这是团队对“长时间稳定性”的内部实现。

- [ ] **M5-02 完成任务二自动化测试**
  - 汇总正常、丢包、重复/乱序、断网与恢复数据。
  - 所有报告数字可追溯到 pcap、日志或原始 CSV。

- [ ] **M5-03 完成任务三对比报告**
  - 固定参数与 AI 使用相同实验条件。
  - 至少两项控制指标和端到端延迟可重新计算。

- [ ] **M5-04 完成官网提交材料**
  - 设计文档：架构、Guest 配置、实时改造、协议、隔离、模型。
  - 测试文档：启动、实时、通信可靠性、端到端延迟和控制对比。
  - 源码与配置：以无冲突 PR 提交目标 `dev` 分支。
  - 复现说明：依赖、构建、镜像、QEMU 命令、实验命令和结果生成。

- [ ] **M5-05 做干净环境复现和 5 分钟视频**
  - 非作者按文档运行核心演示，不依赖未记录文件。
  - 视频展示双终端、通信数据、AI 控制、状态回传和故障降级。

### 最终完成门槛

- 三个任务的官网评分点均有代码、配置、原始数据和文档证据。
- 改造前后、空载/压力、原生 RTOS 基线、网络故障和控制对比均可复现。
- 加分项未完成不影响主线提交。

---

## 11. M6：可选加分项

只有 M1–M5 完成后才能选择，不设主线 Gate。

### M6-A：StarryOS 代替 Linux（4 分）

- [ ] 在 Axvisor 中启动 Starry Guest 并接入任务二网卡。
- [ ] 在 Starry 中运行同一 CPU 小模型和协议程序。
- [ ] 用 Starry 重跑网络、闭环和故障恢复核心测试。

### M6-B：StarryOS syscall 完善（最多 4 分）

- [ ] 只处理主线应用真实触发的 syscall/Linux ABI 阻塞。
- [ ] 先添加确定性失败测试，再修复并运行相关回归。
- [ ] 独立 PR 合入官网要求的 `dev` 分支。

### M6-C：更多基线（2 分）

- [ ] 选择第二种 RTOS 或第二块板卡。
- [ ] 使用同一 workload、指标和分析脚本重跑基线。

以下不在当前计划内：内部通用 vSwitch、NPU 直通、完整串口设备模型、通用 RPC/控制框架。只有主线完成且能明确贡献创新分时，才另立设计与验证任务。

---

## 12. 风险与止损

| 风险 | 最晚止损点 | 处置 |
|---|---|---|
| 双 Guest 资源划分或中断路径不稳定 | M1，3 人日 | 用 Linux+ArceOS 隔离 Axvisor 问题，再替换 RTOS；保留同平台双 Guest 目标 |
| 目标 RTOS 在 QEMU 无可用 virtio-net | M2，2 人日 | 切换候选 RTOS，不在比赛窗口自研通用网络栈 |
| 第二路终端不可用 | M1，1 人日 | 最小 TX/HVC/网络终端；不先实现完整 PL011 |
| 实时改造没有可测收益 | M3 设计评审 | 根据基线换主改造点，不并行铺开多个机制 |
| AI 控制没有优于固定参数 | M4 中期 | 保留诚实的两项对比，简化为神经网络选择预调参数；不伪造改善 |
| 双 NIC 直通出现明确计分否定 | 收到书面答复时 | 重新评估最小替代数据面；默认依据官网允许的虚拟网卡/桥接继续 |

---

## 13. 已确认的仓库约束

- Axvisor 具备多 VM 加载和 vCPU affinity 基础，但 QEMU CI 没有双 Guest 稳定性证据。
- 当前 QEMU Guest 配置多为 `passthrough_devices = [["/"]]`，不能直接复制两份用于双 Guest。
- `virtualization/axdevice` 没有可用的 virtio-net 设备模型，主线依赖 QEMU 设备直通。
- aarch64 没有现成的双串口模拟路径，第二终端需要最小替代方案。
- Guest 侧 ArceOS/Starry 已有 virtio-net 和 IP 栈；目标 RTOS 的 QEMU 网络路径需要实测。
- vIRQ pending 路径使用 `Mutex<BTreeMap<usize, Vec<PendingInterrupt>>>`，可作为基线确认后的实时改造候选。
- RT-Thread 在仓库支持矩阵中只有飞腾派配置；QEMU 主线必须设置明确切换时限。

---

## 14. 每日执行格式

每天只选择一个半天内可验证的主任务：

```markdown
日期：
当前里程碑/TODO：
完成判据：
实际命令：
结果与证据：
阻塞与止损时间：
下一步：
```

---

## 15. 本地 Git 信息与每日检查

### 15.1 当前仓库快照（2026-07-31）

| 项目 | 当前值 |
|---|---|
| 仓库根目录 | `/Users/huxingyu/project/tgoskits` |
| 当前分支 | `dev` |
| 上游分支 | `origin/dev` |
| 远程仓库 | `https://github.com/Huxingyu/tgoskits.git` |
| 当前提交 | `759e69c fix(ax-runtime): restore CRLF for queued console logs (#1695)` |
| 同步状态 | behind 0、ahead 0，与 `origin/dev` 同步 |
| 工作树 | 没有已跟踪文件修改；有 7 个未跟踪的 OpenRace 文档或图片文件 |

未跟踪内容包括周报 DOCX、赛题整理、当前 TODO，以及 `tgoskits-openrace-stack` 的 DOT、Mermaid、PNG、SVG 文件。它们不会进入提交，除非执行 `git add <路径>`。

### 15.2 每次开始工作：30 秒状态检查

```bash
git status --short --branch
git branch -vv
git log -5 --oneline --decorate
git diff --stat
git diff --cached --stat
```

输出含义：

| 命令 | 回答的问题 |
|---|---|
| `git status --short --branch` | 当前分支是什么，有哪些修改、暂存和未跟踪文件？ |
| `git branch -vv` | 本地分支跟踪哪个远程分支，最新提交是什么？ |
| `git log -5 --oneline --decorate` | 最近五个提交及 HEAD、分支、tag 在哪里？ |
| `git diff --stat` | 尚未暂存的修改涉及哪些文件、多少行？ |
| `git diff --cached --stat` | 已暂存且会进入下一次提交的内容是什么？ |

### 15.3 查看具体修改

```bash
git diff
git diff --cached
git diff -- path/to/file
git show --stat --oneline HEAD
```

- `git diff` 查看尚未暂存的完整修改。
- `git diff --cached` 查看已经 `git add` 的完整修改。
- `git diff -- <文件>` 只查看一个文件，适合提交前逐个核对。
- `git show ... HEAD` 查看当前提交包含的文件和变更规模。

### 15.4 判断是否落后远程

先获取远程引用，再比较上游与本地：

```bash
git fetch origin
git rev-list --left-right --count '@{upstream}...HEAD'
git log --oneline --left-right '@{upstream}...HEAD'
```

第二条命令输出两个数字：左侧是 **behind**，右侧是 **ahead**。例如 `3 2` 表示本地落后 3 个提交，同时领先 2 个提交。

> ⚠️ `git fetch origin` 只更新远程引用，不会修改工作区；`git pull` 会把远程提交整合进当前分支，执行前必须先确认本地修改状态。

### 15.5 每次结束工作：保存证据

```bash
git status --short --branch
git diff --check
git diff --stat
git log -1 --format='%H %s'
git rev-parse --show-toplevel
```

将上述输出与实际运行命令、测试日志一起保存到当天记录中。实验报告至少记录 commit hash 和 dirty 状态；否则后续无法确认数据对应哪一版代码。
