# Task1 实时 RTOS 化改造：24 小时探索、修复、实验与评分复盘

> 日期：2026-08-16
> 工作区：`/home/huhu/tgoskits-rt`
> 工作分支：`openrace/task1-rt-partition`
> 文档整理基线：`a1d935c02`（本次文档提交的父提交）
> 评分口径：以 `/home/huhu/todo.md` 对原网页 Task1 要求的整理为准
> 结论口径：只写当前代码、正式归档实验和回归能够支持的事实

---

## 目录

- [1. 最终结论](#1-最终结论)
- [2. 原始任务目标和系统角色](#2-原始任务目标和系统角色)
- [3. 本轮探索的完整时间线](#3-本轮探索的完整时间线)
- [4. 做对了什么，做错了什么](#4-做对了什么做错了什么)
- [5. 代码与机制改造清单](#5-代码与机制改造清单)
- [6. 问题、根因、修复和验证闭环](#6-问题根因修复和验证闭环)
- [7. 正式实验结果](#7-正式实验结果)
- [8. 为什么实时性提升很小](#8-为什么实时性提升很小)
- [9. Claude 审查和双方共识](#9-claude-审查和双方共识)
- [10. 原始 TODO 完成度](#10-原始-todo-完成度)
- [11. 网页评分点完成度](#11-网页评分点完成度)
- [12. 已完成验证与证据质量](#12-已完成验证与证据质量)
- [13. 未解决、阻塞和不确定项](#13-未解决阻塞和不确定项)
- [14. 下一阶段处理顺序](#14-下一阶段处理顺序)
- [15. 当前可以和不可以声称的结论](#15-当前可以和不可以声称的结论)
- [16. 证据索引](#16-证据索引)

---

## 1. 最终结论

本轮工作不是一次单纯的性能调参，而是从测量体系、CPU 拓扑、定时器、虚拟中断、
控制台、锁纪律、实验编排和长时稳定性多个层面，对 AxVisor 的 RT 分区能力进行了
一次系统性核查和修复。

最终得到的结论分成三层。

### 1.1 已经确定完成的部分

1. Zephyr vCPU 可以独占 host pCPU1，Linux 2 个 vCPU 可以稳定运行在 pCPU2、pCPU3。
2. dedicated pCPU1 的 host 周期调度 tick 已经从约 100 次/秒降为严格的 0。
3. vIRQ 软件队列已经有容量上界、显式 overflow 和 retry slot，不再静默无限积压。
4. vMPIDR、Guest affinity 和物理 IRQ affinity 已经解耦，Linux 2-vCPU 拓扑可启动。
5. Guest UART 不再因全局 console mutex 阻塞 Zephyr `printk`。
6. 长时全核停顿最终定位到 `somehal::irq::IRQ_ROUTES` 的 IRQ 重入死锁，并已修复。
7. 四个统一的 1800 秒正式场景全部完成；一小时 `stress-rt` 也完成功能验收。
8. Python、AxVM、AxVisor axtest、somehal、arm_vgic、Clippy、fmt、diff-check 和重要
   证据哈希均已通过。

### 1.2 性能上得到的真实结果

Zephyr 的单次正式结果中，`stress-rt` 相对 `stress-noiso`：

| 指标 | `stress-noiso` | `stress-rt` | 单次差值 |
|---|---:|---:|---:|
| mean | 665.170 us | 614.024 us | 改善 7.69% |
| P99 | 848.032 us | 810.224 us | 改善 4.46% |
| max | 919.488 us | 882.672 us | 改善 4.00% |

但一小时同一 RT profile 的早期 Zephyr 窗口均值为 `728.577 us`、P99 为
`1072.384 us`。这说明跨运行波动大于当前单次改善，因此上述百分比只能描述
这两次具体运行，不能当作统计上已经成立的普遍提升。

Linux Guest 也没有整体改善：平均值由 `510 us` 变成 `604 us`，P99 有所改善，
P99.9 和平均值则变差。因此当前不能声称“整个系统实时性统一提升”。

### 1.3 最终性质判断

本轮显著提高了：

- 正确性；
- CPU 和中断隔离的可验证性；
- 队列有界性；
- 双 Guest 长时运行稳定性；
- 实验数据完整性和失败取证能力。

本轮没有完成或没有证明：

- 真正的固定优先级、就绪即抢占；
- dedicated Zephyr 的 WFI 零陷入快路径；
- 可信的旧代码与新代码正式 A/B；
- 统计显著的全系统平均/P90/P99 改善；
- 一小时内 Zephyr 尾延迟不退化；
- 物理板上的硬实时上界。

严格按证据评分，当前更合理的自评约为 **19-22/30**；完成真实竞争基线、重复实验、
trace 分段数据和 CNTV-only WFI 快路径后，预计可达到 **26-28/30**。

---

## 2. 原始任务目标和系统角色

### 2.1 原始目标

`/home/huhu/todo.md` 给出的总叙事是：

> 把 AxVisor 改造为支持 RT 分区的 hypervisor，使 RTOS vCPU 独占的物理核做到
> 无 tick、无无关中断、无后台任务、就绪即抢占、中断注入有界，并使用 VM-exit
> 计数解释虚拟化带来的每一段延迟。

这个目标同时包含两类要求：

- **机制要求**：绑核、无 tick、抢占、有界中断、正确的 vGIC/timer/WFI 行为。
- **证据要求**：旧/新前后数据、idle/stress、Linux 2-vCPU、native RTOS、长时稳定性。

### 2.2 当前系统中各角色

| 角色 | 当前职责 | CPU 放置 |
|---|---|---|
| AxVisor/Host | EL2、VM 调度、虚拟设备、IRQ 路由、shell、housekeeping | 主要在 pCPU0 |
| Zephyr Guest | 被重点保护和测量的 RTOS | vCPU0 固定到 pCPU1 |
| Linux Guest | cyclictest 测量、stress-ng 负载和 Guest IRQ housekeeping | vCPU0/1 固定到 pCPU2/3 |
| Linux Guest CPU0 | stress-ng、Guest IRQ 和负载侧 | host pCPU2 |
| Linux Guest CPU1 | cyclictest 测量核，配置 `isolcpus=1` | host pCPU3 |

因此 Linux 和 Zephyr 都是 Guest；Linux 不是 Host。研究对象是完整系统，但当前实验
同时保留两条测量线：Zephyr 用于评估 RT 分区保护效果，Linux 用于观察另一分区和
整机长尾是否恶化。

### 2.3 当前四个正式场景的真实含义

| 场景 | Linux 负载 | Zephyr pCPU1 | Host tick | Zephyr profile |
|---|---|---|---|---|
| `idle` | 无 | 已独占 | 保留 | virtualized |
| `stress-noiso` | stress 在 Linux Guest CPU0 | 已独占 | 保留 | virtualized |
| `stress-dedicated` | 同上 | 已独占 | 关闭 | virtualized |
| `stress-rt` | 同上 | 已独占 | 关闭 | passthrough |

这里最重要的事实是：`stress-noiso` 虽然名字带 `noiso`，但 Zephyr 已经独占 pCPU1。
它不是“Zephyr 与 Linux 共享一个物理核”的强竞争基线。这直接限制了后续能够观察到
的提升幅度。

---

## 3. 本轮探索的完整时间线

下面按实际问题推进顺序记录本轮约 24 小时的探索，而不是只列最终成功项。

| 阶段 | 当时的目标或现象 | 实际发现 | 处理结果 |
|---|---|---|---|
| 1. 接管状态 | 读取会话总结、确认分支和 TODO | 分支正确，但工作区包含大量未提交实现和实验资产 | 固定在 `openrace/task1-rt-partition`，不触碰另一 checkout |
| 2. 实现核查 | 检查日志是否和代码一致 | 多处“文档已完成”与真实路径不完全一致 | 逐项从源码、配置、日志和回归交叉核查 |
| 3. 测量体系 | 建立 per-CPU VM-exit 和 Linux/Zephyr 双侧数据 | 原有统计不能区分 host tick 与 Guest event timer | 新增独立 host periodic tick 统计和 CSV 验收 |
| 4. CPU 拓扑 | Linux 2-vCPU 放到 pCPU2/3，Zephyr 放 pCPU1 | vMPIDR、Guest SGI affinity、物理 SPI affinity 原来耦合 | 解耦虚拟和物理 affinity，Guest FDT CPU 编号按 vCPU 重写 |
| 5. Linux 工具链 | 构建静态 cyclictest/stress-ng | rt-tests、libnuma、musl 宏和 Makefile flags 多处不兼容 | 增加 musl patch、numactl 静态库和自动构建脚本 |
| 6. no-tick | 关闭 RT 核 10 ms host 周期 tick | 不能把 Linux 所在 pCPU2/3 也标 dedicated | host mask 从错误的 `1,2,3` 收窄为 `1` |
| 7. WFI 快路径 | 原计划 dedicated 就清 TWI | CNTP 仍软件模拟，直接清 TWI 可能导致 Guest 永久睡眠 | 改为 timer capability policy，当前保守地继续 trap WFI |
| 8. 抢占尝试 | 启用 RR/preempt/IPI，给 RT 任务 priority 90 | Guest world switch 中发生 EL2 data abort | 回退 RR/preempt |
| 9. IPI 尝试 | 单独保留 IPI 处理跨核唤醒 | 与 dedicated CPU 组合后次核启动停在 50% | 回退 IPI，恢复 4/4 启动 |
| 10. 首轮 smoke | 跑 Linux cyclictest 和 Zephyr sampler | Zephyr 在 Linux workload 前已经完成 | 增加 UART start gate 和顺序验收 |
| 11. 样本核算 | 5000 loops 的直方图只出现少量 bucket | 大部分样本在 histogram 上界之外，被误当成缺失 | 把 overflow 纳入 `bucket + overflow = total` 强验收 |
| 12. Linux affinity | cyclictest/stress CPU 角色反了 | 测量核、isolated 核和负载核配置相互矛盾 | 测量固定 Guest CPU1，负载/IRQ 固定 Guest CPU0 |
| 13. Console stall | Zephyr 停在 `printk`，怀疑 timer | Guest UART 每次 I/O 竞争全局 `ConsoleState` mutex | 改成每 endpoint bounded ring，housekeeping 异步 drain |
| 14. 正式 loop 实验 | 用 180 万次、1 ms 推导 30 分钟 | TCG 下固定 loop 数不等于固定 Guest 时间 | 正式实验改用 cyclictest `-D` duration |
| 15. Duration 验收 | runner 墙钟与 Guest 时间差异很大 | wall time 不能证明 Guest 内运行满 1800 秒 | 记录 Guest `/proc/uptime` 前后差作为验收 |
| 16. TCG 预算 | scale 1、2 长实验超时 | 短 smoke 无法预测 30 分钟 TCG 进度 | 引入校准、scale 3 fallback 和 progress watchdog |
| 17. 长时 stall | Guest uptime 在 659 s、1710 s 等位置停止 | 不是 panic；QMP 仍显示 VM running | watchdog 自动采 QMP、寄存器和串口证据 |
| 18. 死锁定位 | 四核都停在 spin acquire | 同一锁地址解析为 `somehal::irq::IRQ_ROUTES` | Git 考古到锁迁移后读路径漏用 irqsave |
| 19. 死锁修复 | 普通上下文持锁时被硬 IRQ 重入 | 同 CPU 递归获取同一 SpinLock，随后全核争用 | 所有 route registry 访问统一 `lock_irqsave()`，增加失败回归 |
| 20. 修复验证 | 跨过原 1710.75 s 故障点 | 180 万样本正常完成，无 `post-stall/` | 死锁闭环成立 |
| 21. 正式矩阵 | 四场景统一跑 1800 Guest 秒 | 全部完成，但 `stress-noiso` 首次在结果排空阶段失败 | drain timeout 从硬编码 30 s 改为默认 180 s |
| 22. 一小时稳定性 | 验证 RT 分区长期不死锁 | 功能稳定，但 Linux P99 明显变差 | 只声明功能稳定和 no-tick，不声明长尾稳定 |
| 23. 性能复盘 | Zephyr 单次数据有 4%-8% 改善 | 同 RT profile 不同运行的波动高达 18.7%/32% | 撤回“已证明显著提升”的强结论 |
| 24. Claude 独立审查 | 检查是否遗漏主瓶颈 | 主开销是 WFI+timer wheel+task switch，基线也不够强 | 下一阶段转向 CNTV-only WFI fast path、重复实验和真实竞争基线 |

---
## 4. 做对了什么，做错了什么

### 4.1 本轮做对的关键事情

| 正确做法 | 为什么重要 | 当前证据 |
|---|---|---|
| 不把长时 stall 简单归因于 QEMU 慢 | QMP 显示 VM running，说明需要继续取证 | `diagnostic-1800-2026-08-16/idle/post-stall/` |
| 为失败增加 watchdog 后取 QMP/寄存器快照 | 最终把四核停顿定位到同一个锁地址 | `IRQ_ROUTES` 符号解析和锁回归 |
| 行为修复先写旧实现失败的回归 | 避免“看起来合理但没有覆盖真实 bug” | IRQ route、console、source hygiene、runner 合同等回归 |
| 把 Guest 时间与 runner 墙钟分开 | TCG 下 wall time 无法表示 Guest 实际运行时长 | `/proc/uptime` progress 验收 |
| 把 histogram overflow 纳入总样本 | 防止将超出直方图范围的长尾样本静默丢失 | `bucket + overflow = total` |
| 给 Zephyr 加 workload start gate | 保证 300 个样本真正位于 Linux 压力窗口 | START/COMPLETE 顺序验收 |
| 把 host periodic tick 单独统计 | 避免把 Guest timer/WFI exit 当作 host tick | `host-periodic-ticks.csv` |
| 对旧结果保留失败证据而不补造数据 | 保持实验可审计性 | failed directories、旧哈希漂移说明 |
| 对 WFI 采用能力判断而非盲目清 TWI | 保证 CNTP 软件模拟路径不会丢失唤醒 | `wfi.rs` 三个策略测试 |
| 抢占和 IPI 出现架构性错误后及时回退 | 保住可运行基线，没有用不稳定机制换漂亮数据 | 当前 4/4 启动和正式矩阵 |
| 同时观察 Zephyr 和 Linux | 防止只优化一个 Guest 后声称全系统改善 | Linux/Zephyr 双侧结果表 |

### 4.2 被证伪或修正的判断

| 原判断或假设 | 为什么错误 | 修正后的认识 |
|---|---|---|
| `stress-noiso` 是未隔离强基线 | Zephyr 在所有场景都固定到 pCPU1 | 它只是“已有物理隔离但仍有 host tick”的基线 |
| dedicated CPU 就可以直接不 trap WFI | Guest CNTP 仍软件模拟 | 只有所有实际暴露 timer 都能硬件唤醒时才可清 TWI |
| 打开 `sched-rr + preempt` 就能获得实时抢占 | world switch 状态可能在 IRQ 尾部被任务切换破坏 | 必须定义 vCPU context 临界区和延迟抢占边界 |
| 单独开启 IPI 已经足够安全 | dedicated + SMP4 次核启动停在 50% | 必须先根治启动/唤醒 race，再接入远程抢占 |
| 180 万次、1 ms 就等于 1800 秒 | TCG 下 Guest 进度和 wall time不稳定 | 正式使用 `-D`，以 Guest uptime 验收 |
| 20 秒 smoke 能预测 30 分钟预算 | 长运行出现非线性减速和死锁 | smoke 只验证流程，长测必须有 progress watchdog |
| Zephyr sampler 已与 Linux stress 同时运行 | 旧编排让 Zephyr 在 Linux workload 前完成 | 用 UART gate 严格控制窗口 |
| histogram bucket 数就是总样本数 | 超界样本进入 overflow | 必须保存 overflow 并做等式验收 |
| Zephyr 停在 `printk` 是 timer 失效 | Guest UART 在等全局 console mutex | 使用独立 bounded endpoint ring |
| timer/WFI exit 数等于 host 周期 tick | event-driven Guest timer 也会产生相同 exit 类别 | 增加独立 host periodic tick 计数 |
| Linux cmdline 有 `nohz_full=1` 就已生效 | Guest kernel 缺少 `CONFIG_NO_HZ_FULL` | 只能声明 affinity/IRQ 分离 |
| vGIC LR 耗尽需要新增 Task1 retry 接线 | 上游已通过 maintenance PPI 和 LR refill 覆盖 | 只做验证和回归，不重复实现 |
| 临时 DBG 日志已清理 | source review 发现仍有残留 | 增加 source hygiene 回归后删除 |
| 30 秒足够排空实验最终结果 | 约 720 行 CPU stat 实际需要 39.36 秒 | `RT_RESULT_DRAIN_TIMEOUT_SEC` 默认 180 秒 |
| 4%-8% 单次改善足以证明优化有效 | 同 RT profile 独立运行波动更大 | 需要交错重复实验和统计区间 |
| 只要 Zephyr 变好就代表整个系统变好 | Linux 平均值和 P99.9 可能同时变差 | 必须分别报告两个 Guest 和整体权衡 |

### 4.3 本轮最重要的认识变化

开始时关注的是“如何关闭 RT 核的 10 ms host tick”。结束时发现，no-tick 是正确且
必要的隔离机制，但不是当前 QEMU TCG 延迟的主导项。当前最大的可优化路径是：

```text
WFI trap
  -> 软件 timer wheel
  -> vCPU task park
  -> timer worker wake
  -> cooperative FIFO 重新调度
  -> CNTV host IRQ exit
  -> vGIC 注入
  -> Guest ISR
  -> interrupt deactivate exit
```

换句话说，本轮成功去掉了“环境噪声中的一个固定干扰源”，但尚未去掉“每次周期唤醒
必经的虚拟化控制路径”。

---

## 5. 代码与机制改造清单

| 改造 | 主要代码位置 | 当前状态 | 实际价值 |
|---|---|---|---|
| per-CPU VM-exit reason 计数 | `virtualization/axvm/src/vmexit_stats.rs`、AArch64 exit path、`vmexit stat` | 完成 | 能按 CPU 和原因解释退出率 |
| vMPIDR 与物理放置解耦 | `virtualization/axvm/src/arch/aarch64/vm.rs`、`arm_vgic` affinity | 完成 | Linux vCPU0/1 可放到 pCPU2/3 |
| Guest FDT CPU 重编号 | `virtualization/axvm/src/boot/fdt/core/` | 完成 | Guest SMP 看到连续虚拟 CPU ID |
| Linux 2-vCPU RT 拓扑 | `scripts/test/rt-partition/*.toml` | 完成 | 满足多核 Linux 交付主体 |
| dedicated pCPU no-tick | `os/arceos/modules/axruntime/src/lib.rs`、AxVisor bootargs | 完成 | pCPU1 host 周期 tick 严格为 0 |
| WFI capability policy | `virtualization/axvm/src/arch/aarch64/wfi.rs` | 完成但保守 | 防止不安全清 TWI；尚未获得 WFI fast path |
| cyclictest/stress-ng 静态工具链 | `build-rt-tools.sh`、musl patches | 完成 | 可重复构建 Guest 测量环境 |
| duration/progress 实验 runner | `run-cyclictest.sh`、`rt-linux-init.sh` | 完成 | 支持正式 30/60 分钟实验和失败取证 |
| Zephyr workload gate | `scripts/test/zephyr-periodic/src/main.c`、serial driver | 完成 | 保证 RTOS 样本与 Linux workload 重叠 |
| histogram overflow accounting | `cyclictest-hist-to-csv.py` | 完成 | 长尾样本不再从分母消失 |
| Guest console bounded rings | `os/axvisor/src/guest_console/mux/` | 完成 | Guest UART 不再等待全局 console/output lock |
| bounded vIRQ queue + retry slot | `virtualization/axvm/src/runtime/{queue,dispatcher}.rs` | 完成 | 队列容量 64、overflow 显式、edge 不丢失 |
| vGIC maintenance 验证 | `arm_vgic`、`results/task1/vgic-maintenance.md` | 完成 | 确认现有 LR refill 正确，无重复接线 |
| 锁路径 trace 分段 | `runtime/trace.rs`、dispatcher | 接口完成 | formal run 尚未启用 trace |
| `IRQ_ROUTES` IRQ-save 锁修复 | `platforms/somehal/src/irq.rs` | 完成 | 修复随机长时全核死锁 |
| 固定优先级抢占 | axtask/AxVisor features | 未完成，已回退 | 当前仍是 cooperative FIFO |
| 远程 reschedule IPI | axtask/AxVM host ops | 未完成，已回退 | dedicated + SMP4 组合仍有启动 race |
| CNTV-only WFI fast path | timer profile/FDT/WFI policy | 未实现 | 下一阶段最高潜在收益项 |

### 5.1 分类提交前的工作区规模

分类提交前，已跟踪文件相对当时 HEAD 的 diff 约为：

- 45 个已跟踪文件发生变化；
- 约 2727 行新增、664 行删除；
- 另有设计文档、实验数据、回归测试和新模块等未跟踪文件。

这说明本轮不是只改了一个定时器开关，而是覆盖了运行时、调度、虚拟化、GIC、console、
测试脚本和证据归档。当前实现现已分类提交；但正式实验运行时来自 dirty tree，实验
manifest 记录的是当时旧 HEAD，因此历史二进制与最终提交之间仍不能声称严格一一对应。

---

## 6. 问题、根因、修复和验证闭环

| 问题/现象 | 根因 | 修复 | 验证结果 |
|---|---|---|---|
| Linux 2-vCPU 放到 pCPU2/3 后 SMP/SGI 语义可能错误 | vMPIDR、Guest affinity 和物理 IRQ affinity 共用同一编号 | 拆分 guest/physical affinity，Guest FDT 按 vCPU 编号生成 | arm_vgic 回归、AxVM 测试、正式 Linux 2-vCPU 启动通过 |
| Linux Guest `sleep`/cyclictest 停滞 | `dedicated_cpus=1,2,3` 关闭了 Linux 所在 pCPU2/3 的 host timer | 只设置 `dedicated_cpus=1` | 四场景正式运行完成 |
| 直接清 TWI 可能丢唤醒 | CNTV 可硬件 wake，但 CNTP 仍软件模拟 | capability-gated `trap_wfi` | 三种能力组合单测通过；当前继续 trap WFI |
| RR/FIFO preempt 下 EL2 data abort | IRQ 中发生调度，vCPU world-switch/VGIC/deferred IRQ 状态未闭合 | 回退抢占，保留稳定 FIFO | 回退后 axtest 和正式双 Guest 通过 |
| IPI + dedicated 次核启动 50% 卡住 | dedicated 启动/等待与 IPI 存在未闭合 race | 回退 IPI | 4/4 physical cores 稳定启动 |
| Zephyr 在 `printk` 停滞 | Guest UART I/O 竞争全局 `ConsoleState` 和 host writer | 每 endpoint 64 KiB bounded ring，housekeeping drain | console lock 回归和 AxVisor axtest 通过 |
| Zephyr 样本没有覆盖 Linux stress | sampler 自动开始太早 | UART start gate，runner 等 Linux START 后触发 | 顺序验收通过 |
| cyclictest 5000 样本只看到几百 bucket | 大量样本超过 histogram range | 保存 overflow 并要求 bucket+overflow=total | 5000/5000 和正式百万级样本计数闭合 |
| 180 万 loops 长测超时 | TCG 下固定 loop 不等于固定 Guest 时间 | 正式改 `-D` duration，Guest uptime 验收 | 四场景约 1792-1795 Guest 秒 |
| duration scale 1/2 仍超时 | TCG 进度长期非线性，短 smoke 不可外推 | 校准、scale 3 fallback、300 秒 progress watchdog | 正式矩阵最终完成 |
| 长时运行在 659/1710 秒无响应 | `IRQ_ROUTES` 从 `SpinNoIrq` 迁移后，读路径仍使用只禁抢占的 `.lock()`；硬 IRQ 同 CPU 重入 | 所有 route lookup 改走 `lock_irqsave()` helper | 旧实现失败回归；修复后跨过故障点并完成 180 万样本 |
| `stress-noiso` workload 完成后 runner 判失败 | 720 行最终 CPU stat 排空超过硬编码 30 秒 | drain timeout 默认 180 秒并纳入 meta/预算 | 成功复跑实际 drain 39.36 秒 |
| 旧实验哈希漂移 | 哈希指向会被重新构建覆盖的 `tmp/`/`target/` 文件 | 将实际构建输入复制到场景目录后做相对路径哈希 | 新正式矩阵全部哈希通过；旧结果不伪修 |
| `nohz_full=1` 没有效果 | Linux Guest kernel 未启用 `CONFIG_NO_HZ_FULL` | 文档收窄声明 | 只声称 affinity 和 IRQ/load 分离 |
| vGIC 是否缺 EOI retry 不确定 | 对当前 upstream 机制理解过时 | 核查 UIE/NPIE/LRENPIE/TDIR、maintenance PPI、save/refill | LR 一满两 edge 回归证明不丢不重 |
| formal trace 没有阶段数据 | 正式场景 `realtime_trace=disabled` | 当前只完成 trace 接口和文档 | 仍需 instrumented formal run |

---

## 7. 正式实验结果

### 7.1 四场景 1800 秒正式矩阵

所有场景均使用 duration 模式，并以 Guest `/proc/uptime` 覆盖请求时长。四个接受结果
均通过归档哈希，且没有 watchdog `post-stall/`。

| 场景 | Linux 样本 | Linux min/avg/max | Zephyr mean/P99/max | Guest progress | pCPU1 host tick |
|---|---:|---:|---:|---:|---:|
| `idle` | 1,713,691 | 126/534/304645 us | 601.023/866.560/914.768 us | 1792.17 s | 保留 |
| `stress-noiso` | 1,746,156 | 139/510/303853 us | 665.170/848.032/919.488 us | 1794.90 s | 约 98.7/s |
| `stress-dedicated` | 1,727,468 | 151/578/302045 us | 711.746/1029.120/1067.168 us | 1794.86 s | 0 |
| `stress-rt` | 1,720,603 | 149/604/303101 us | 614.024/810.224/882.672 us | 1795.09 s | 0 |

从这张表能得出三个不同层面的结论：

1. **功能和样本完整性成功**：四场景均运行到约 1800 Guest 秒，百万级样本闭合。
2. **no-tick 机制成功**：dedicated 场景 pCPU1 在 before、Zephyr-after、Linux-final
   三次快照全部 `count=0, delta=0`。
3. **端到端性能结论有限**：Zephyr 单次结果有改善，但 Linux 平均值没有改善，
   且跨运行波动大于单次差值。

### 7.2 Zephyr 单次相对改善

`stress-rt` 相对 `stress-noiso`：

| 指标 | 差值 | 百分比 |
|---|---:|---:|
| mean | -51.146 us | -7.69% |
| P99 | -37.808 us | -4.46% |
| max | -36.816 us | -4.00% |

`stress-rt` 相对 `stress-dedicated`：

| 指标 | 差值 | 百分比 |
|---|---:|---:|
| mean | -97.722 us | -13.73% |
| P99 | -218.896 us | -21.27% |
| max | -184.496 us | -17.29% |

但 `stress-dedicated` 在 host 干扰更少的情况下反而比 `stress-noiso` 更差，说明 QEMU
TCG 和运行间噪声足以覆盖几十微秒级的机制差异。

### 7.3 Native Zephyr 基线

同一 Zephyr 周期应用直接运行于 QEMU、不经过 AxVisor：

| 指标 | Native QEMU | `stress-rt` | 虚拟化后差异 |
|---|---:|---:|---:|
| mean | 405.783 us | 614.024 us | +51.32% |
| P99 | 599.056 us | 810.224 us | +35.25% |
| max | 836.048 us | 882.672 us | +5.58% |

Native 自身均值已约 `406 us`，说明当前 QEMU TCG 平台存在很高的基础计时/调度噪声。
即使 AxVisor 完全消除几十微秒级干扰，也不容易在单次 300 样本中稳定显示。

### 7.4 一小时 `stress-rt` 稳定性

| 项目 | 结果 |
|---|---:|
| Linux 完整样本 | 3,347,556 |
| Guest elapsed | 3598.96 s |
| Guest/host progress ratio | 1.000018463 |
| Zephyr | 300/300 |
| pCPU1 host periodic tick | 三次快照全部 0 |
| watchdog/post-stall | 无 |
| sha256 | 全部通过 |

Linux 长尾对比：

| 运行 | avg | P90 | P95 | P99 | P99.9 | max |
|---|---:|---:|---:|---:|---:|---:|
| 30 分钟 `stress-rt` | 604 us | 821 us | 894 us | 1060 us | 8695 us | 303101 us |
| 一小时 `stress-rt` | 679 us | 872 us | 950 us | 2061 us | 9212 us | 304760 us |

一小时运行证明了系统不再死锁、Guest 时间正常推进、样本和哈希完整、RT 核无 host tick。
但 Linux P99 增加 94.43%，所以不能把它描述成“长时尾延迟稳定”。

Zephyr 一小时运行的早期窗口为：

| mean | P99 | max |
|---:|---:|---:|
| 728.577 us | 1072.384 us | 1164.672 us |

Zephyr 只在 workload 开始附近采 300 点，没有贯穿一小时的窗口，因此不能判断其尾延迟
在何时、为何发生变化。

### 7.5 vIRQ 过载/积压实验

该实验是同一到达/服务序列下的确定性队列 replay，不是 QEMU 端到端 WCET：

| 模型 | accepted | overflow | max depth | P99 latency | max latency |
|---|---:|---:|---:|---:|---:|
| 旧无界队列 | 2000 | 0 | 1901 | 1881.05 ms | 1900.05 ms |
| 当前容量 64 | 163 | 1837 | 64 | 64 ms | 64 ms |

这项结果明确证明了“有界性”改造：过载时当前实现显式拒绝多余请求，并把常驻深度和
排空延迟封顶；旧实现则让积压随过载持续增长。

### 7.6 VM-exit 证据

Zephyr 测量窗口内 pCPU1 的主要累计变化：

| 场景 | IRQ | timer | WFI | MMIO |
|---|---:|---:|---:|---:|
| `stress-noiso` | 15471 -> 17273 | 15365 -> 17072 | 15364 -> 17071 | 46395 -> 78618 |
| `stress-rt` | 14978 -> 16602 | 14970 -> 16594 | 14970 -> 16595 | 45210 -> 77184 |

IRQ、timer、WFI 增量接近 1:1:1，说明 dedicated/no-tick 后，周期路径仍然保持：

```text
WFI trap -> timer wake -> Guest timer interrupt -> deactivate
```

no-tick 消除的是 host 周期调度 tick，不是 Guest 自身每个周期必需的 timer/WFI/IRQ
控制路径。

---

## 8. 为什么实时性提升很小

### 8.1 基线本来就已经隔离

`stress-noiso` 中 Zephyr 已固定到 pCPU1，Linux 固定到 pCPU2/3，Host housekeeping
主要位于 pCPU0。`stress-rt` 并不是从“同核激烈竞争”变为“独占核”，而是从“已经
物理分开”变成“关闭 pCPU1 host tick，并切换 Zephyr profile”。

因此可消除的干扰预算本来就不大。

### 8.2 优化掉的是约 51 us，留下的是约 208 us

按均值粗略分解：

```text
Native QEMU floor                  ~= 405.783 us
stress-rt                          ~= 614.024 us
AxVisor/虚拟化剩余固定开销          ~= 208.241 us
stress-noiso - stress-rt           ~=  51.146 us
```

本轮只回收了约 51 us，而 WFI trap、timer wheel、timer worker、vCPU park/wake、FIFO
重调度和 vGIC 路径留下了约 208 us 的平均差距。

### 8.3 WFI 仍然陷入，主路径未被缩短

当前 `TIMER_WAKE_CAPABILITIES` 为：

```text
virtual_timer = true
physical_timer = false
```

因为 Guest FDT 仍暴露物理 timer，CNTP 仍由软件模拟，dedicated Zephyr 不能安全地
直接清除 TWI。这导致每个 10 ms 周期继续走软件 wait path。

### 8.4 cooperative FIFO 没有真正优先级

`RT_TASK_PRIORITY=90` 已写入 vCPU、timer worker 和注入器任务，但当前
`FifoScheduler::set_priority()` 返回 `false`。高优先级任务 ready 后并不会立即抢占
低优先级任务。

所以原始方案中预期产生大幅差异的“就绪即抢占”机制并未交付。

### 8.5 仍有跨分区共享锁

`virtualization/axvm/src/timer.rs` 中所有 CPU 的 timer wheel 位于同一个：

```rust
static TIMER_WHEELS: OnceLock<IrqSafeMutex<TimerWheels>>
```

Linux vCPU 和 Zephyr vCPU 的 timer 注册、取消和到期处理仍可能争用同一全局锁。它是
真实的跨分区耦合，虽然本轮没有测出其独立贡献。

### 8.6 QEMU TCG 噪声和样本量限制

- Native 均值已经约 406 us；
- 所有正式 Zephyr 场景只有 300 个样本；
- 30 分钟和一小时同 RT profile 的早期窗口差异大于单次优化差值；
- Linux 所有场景都有约 302-305 ms 的极端 max，明显受 Host/TCG 影响。

因此几十微秒级变化在当前环境中很容易被运行间噪声覆盖。

### 8.7 结论

当前最准确的表述是：

> RT 分区实现显著改善了隔离正确性、有界性和功能稳定性；Zephyr 单次时间数据出现
> 4%-8% 改善，但该差值小于已观察到的跨运行波动，尚不能作为统计显著的端到端提升。

---

## 9. Claude 审查和双方共识

Claude 的原始 stdout 保存在：

- `../../../Library/Application Support/AI Expert Reviews/claude-20260816-082346.Dogd0O/raw-claude-stdout.txt`

### 9.1 完全一致的判断

| 判断 | Claude | 本轮复核 |
|---|---|---|
| `stress-noiso` 已经物理隔离 | 同意 | 源码和配置确认 |
| host tick 是次要干扰源 | 同意 | exit 和均值预算支持 |
| 单次改善小于运行间波动 | 同意 | 614.024 vs 728.577 us |
| WFI/timer wheel/task switch 是主要剩余路径 | 同意 | 1:1:1 exit 和源码路径支持 |
| FIFO priority 是 no-op | 同意 | `FifoScheduler::set_priority=false` |
| 不能声称全系统统一改善 | 同意 | Linux 平均/P99.9 混合变化 |
| 不能直接重新打开抢占 | 同意 | 已有 EL2 data abort 证据 |
| CNTV-only WFI fast path 是高价值方向 | 同意 | 但必须补安全闭环 |
| 需要真实竞争基线和重复实验 | 同意 | 原正式矩阵不能建立强因果 |

### 9.2 需要加条件的 Claude 判断

1. **“same-config repeats”**：30 分钟和一小时运行使用相同代码和 RT profile，但请求
   时长不同，严格说不是完全受控重复；它们足以证明存在明显运行间波动，但还需要正式
   交错重复实验。
2. **“Zephyr never touches CNTP”**：pCPU1 的 `sysreg` 和 `nothing` exit 都为 0，
   强烈支持观测窗口内没有 CNTP 软件模拟访问；但当前 FDT 仍暴露 CNTP，不能把历史
   观测当作永久契约。应先建立 CNTV-only profile。
3. **“WFI fast path 可改善 50-150 us”**：这是合理工程估计，不是已经测得的结果。
4. **当前评分 19-22**：这是严格证据口径；如果评委更重视工程实现本身，可能高一些，
   但当前不能按 25+ 的乐观口径准备答辩。

### 9.3 双方共同建议

下一阶段不应继续围绕 host tick 做微调，而应转向：

1. 让后续实验只从 clean commit 构建，并在 manifest 中记录该 commit；
2. 增加真正共享 pCPU1 的竞争基线；
3. 启用 trace，测量 IRQ/source 到 Guest ISR 的阶段延迟；
4. 建立 CNTV-only timer profile，安全消除 WFI trap；
5. 拆分全局 timer-wheel 锁；
6. 最后再以明确临界区和组合回归实现固定优先级抢占。

---

## 10. 原始 TODO 完成度

| TODO | 原目标 | 当前状态 | 已完成 | 未完成/偏差 |
|---|---|---|---|---|
| T0.1 旧实验资产 | 抢救 `/tmp/ab-*.log`、`e1-*.log` 并复算 | 部分完成 | day4-6 可恢复资产、文档和 sha256 已归档 | 原实验机 `/tmp` 文件仍缺失，311->301 us 不能复算 |
| T0.2 exit reason | per-CPU、per-reason、shell 速率 | 完成 | 12 类 exit、cacheline 原子、`vmexit stat` | formal trace 未启用，不等于阶段延迟 |
| T0.3 vMPIDR 解耦 | vCPU ID 与 pCPU 放置分离 | 完成 | MPIDR、FDT、Guest/physical affinity 解耦 | 无主要剩余项 |
| T0.4 Linux 2-vCPU | Linux 2 核、Zephyr 独占核、分配表 | 完成 | Linux vCPU0/1 -> pCPU2/3，Zephyr -> pCPU1 | Guest kernel 无 `CONFIG_NO_HZ_FULL` |
| T0.5 Linux 测量 | cyclictest、stress-ng、自动归档 | 完成 | 静态工具、duration runner、CPU stat、CSV、hash | Linux P99/P99.9 尚未直接写入基础 summary 文件 |
| T1.1 RT 核 tick 隔离 | dedicated 核无 10 ms host tick | 完成 | pCPU1 三次快照均严格为 0 | 只消除 host tick，不消除 Guest timer exit |
| T1.2 RT 分区 profile | passthrough、绑核、no-tick、WFI fast path | 部分完成 | profile、绑核、passthrough、capability policy | WFI 仍 trap，未实现 exit 约 0 |
| T2.1 调度抢占 | 高优先级 vCPU ready 即抢占 | 未完成 | 失败路径和原因已记录，priority intent 已标注 | RR/FIFO preempt 崩溃，IPI dedicated startup race 未修 |
| T2.2 三组/四组矩阵 | idle、stress no-RT、stress RT 正式对比 | 流程完成、原意部分完成 | 四场景 1800 秒统一矩阵通过 | `stress-noiso` 已独占核；缺真正的共享核竞争基线和重复实验 |
| T2.3 长时稳定性 | 一小时及以上稳定运行 | 功能完成 | 一小时样本、进度、no-tick、hash 全通过 | Linux P99 退化；Zephyr 没有全时段窗口 |
| T3.1 过载/积压 | 旧无界 vs 新有界最坏情况 | 队列级完成 | 确定性 replay 证明深度和延迟封顶 | 不是端到端 QEMU/板级 WCET |
| T3.2 vGIC EOI retry | 先核实后接线 | 完成 | 证明现有 maintenance/refill 已覆盖 | 硬件 maintenance latency 无上界数据 |
| T3.3 锁临界区 | trace 分段、锁顺序、死锁文档 | 机制/文档完成 | queue/wake 分段、锁纪律、三类死锁闭环 | 正式实验 `realtime_trace=disabled` |
| T3.4 native RTOS | 同应用 native QEMU 基线 | 完成 | 300 样本、镜像、命令、stats、hash | QEMU 构建需进一步统一归档；无物理板 |
| T3.5 物理板 | 香橙派复跑矩阵 | 阻塞 | 无 | 当前没有物理板环境 |
| T4.1 设计文档 | 正式设计、关键路径、限制 | 完成 | `book/design/task1-realtime-design.md` | 需根据严格统计结论继续收紧措辞 |
| T4.2 results 索引 | 每项实验可复现索引 | 完成 | `results/task1/README.md` | 可增加本复盘报告入口 |
| T4.3 PR 拆分 | 分机制 commit/PR 和 CI | 部分完成 | 代码、测试流水线、证据和文档已分类为本地提交 | 尚未创建 PR、推送远端或接入 CI；大构建产物保持本地 |

---

## 11. 网页评分点完成度

以下不是官方评分，而是结合代码、实验和 Claude 严格审查后的保守自评。

| 评分点 | 满分 | 已完成证据 | 主要缺口 | 严格自评 |
|---|---:|---|---|---:|
| 目标与关键路径分析 | 4 | 完整设计文档、VM-exit 分类、WFI/timer/vGIC/锁路径分析 | formal trace 关闭；无真实 IRQ-to-Guest-ISR 分段直方图 | 3/4 |
| 关键机制实质改造 | 8 | no-tick、vMPIDR/affinity、bounded vIRQ、console 隔离、WFI policy、IRQ 死锁修复 | 固定优先级抢占未完成；WFI fast path 未完成；仍有全局 timer-wheel 锁 | 4-5/8 |
| 多核 Linux 配置合理 | 4 | Linux 2-vCPU、Guest CPU1 测量、CPU0 load/IRQ、host pCPU2/3、分配表、正式启动 | Guest `NO_HZ_FULL` 未编译 | 4/4 |
| 改造前后数据/最坏情况 | 5 | no-tick 98.7/s->0、有界队列 A/B、四场景数据、native 对比 | 缺可重建旧代码正式 A/B；单次延迟差小于运行波动 | 2/5 |
| idle vs stress 对比 | 4 | 四场景 1800 秒矩阵、Linux/Zephyr 双侧数据 | 无真正共享核竞争基线；无 3-5 次重复 | 2-3/4 |
| RTOS native 基线可复现 | 5 | 同一 Zephyr 应用、native QEMU 命令/镜像/stats/hash | 无物理板；Native/AxVisor QEMU 二进制一致性需更严格固定 | 4/5 |
| **总计** | **30** | | | **19-22/30** |

### 11.1 为什么不是此前乐观估计的约 25 分

此前估计默认评委会直接认可：

- `stress-noiso -> stress-rt` 的单次百分比；
- 当前矩阵已经等价于“未隔离 vs RT 分区”；
- priority 90 可以作为抢占机制的一部分；
- 一小时成功即代表尾延迟稳定。

代码和数据复核后，这四点都不能成立。分数下调主要来自证据口径收紧，而不是已有代码
突然失效。

### 11.2 达到 26-28 分所需的关键增量

| 增量 | 主要提升评分项 |
|---|---|
| 真正的共享 pCPU1 竞争基线 | idle/stress、前后数据 |
| 每场景 3-5 次交错重复和统计区间 | 前后数据可信度 |
| trace-enabled IRQ-to-ISR 分段实验 | 关键路径分析 |
| CNTV-only WFI untrap | 实质机制、前后数据、RTOS 基线 |
| 安全固定优先级抢占 | 实质机制、stress 场景 |
| 物理板复跑 | 所有性能证据可信度 |

---

## 12. 已完成验证与证据质量

### 12.1 最终回归

| 验证 | 结果 |
|---|---|
| Python RT-partition/console/build contracts | 38/38 |
| AxVM host tests | 286/286 |
| AxVisor AArch64 axtest | 84/84，`AXTEST_SUITE_OK` |
| somehal IRQ route locking regression | 通过 |
| arm_vgic source hygiene | 通过 |
| somehal `cargo check --tests` / Clippy | 通过 |
| AxRuntime `cargo check --tests` | 通过 |
| AxRuntime 基础和 `irq,multitask,smp` Clippy | 通过 |
| 正式 AArch64 双 Guest release build | 通过 |
| `cargo fmt --all -- --check` | 通过 |
| `git diff --check` | 通过 |
| formal matrix/stability/native/overload/virq-ab sha256 | 通过 |

### 12.2 验证边界

- `cargo test -p ax-runtime` 和完整 somehal host test binary 会因为裸机 linker script
  符号缺失而无法在普通 host linker 上运行；当前使用 `cargo check --tests` 和目标回归。
- 完整 AxRuntime feature matrix 中 `aic8800-wifi` 需要外部下载固件，网络连接被拒绝；
  这不是本轮源代码 lint 失败。
- QEMU TCG 数据用于相同环境下趋势分析，不构成硬件 WCET。
- 正式场景运行时来自 dirty tree；二进制已哈希，当前源码也已提交，但旧 manifest
  没有记录最终 clean commit，因此不能证明历史二进制与最终提交逐字节对应。

---

## 13. 未解决、阻塞和不确定项

| 类型 | 问题 | 当前影响 | 解决条件 |
|---|---|---|---|
| 未解决 | 固定优先级 vCPU 抢占 | 原任务“就绪即抢占”未兑现 | 明确 vCPU context 临界区、deferred resched、组合回归 |
| 未解决 | IPI + dedicated 启动 race | 无法可靠远程 kick hardware-WFI Guest | 根因复现、wake-before-wait 修复、SMP4 矩阵 |
| 未解决 | WFI 仍 trap | 每周期仍有软件 timer wheel 和两次 task switch | CNTV-only profile、FDT 限制、stop/vIRQ kick 验证 |
| 未解决 | 全局 `TIMER_WHEELS` mutex | Linux/Zephyr timer 跨分区耦合 | 拆为 per-CPU wheel/lock并增加跨 CPU cancel 测试 |
| 未解决 | 真正竞争基线缺失 | 当前 noiso/RT 差异天然很小 | host competitor 或共享 pCPU vCPU 的受控场景 |
| 未解决 | 重复统计缺失 | 不能证明 4%-8% 超过噪声 | 同构建、交错顺序、每场景 3-5 次 |
| 未解决 | Zephyr 一小时连续采样缺失 | 不能判断首尾窗口和漂移 | 多窗口或连续 bounded buffer sampler |
| 未解决 | formal realtime trace 关闭 | 没有各阶段延迟归因 | 单独 trace-enabled instrumented run |
| 不确定 | WFI fast path 实际收益 | 预计 50-150 us，但未实测 | 实现后同口径 A/B |
| 不确定 | Linux 约 300 ms max 来源 | 可能是 Host/TCG 调度或 QEMU thread 抖动 | pin QEMU threads、采 Host trace、重复实验 |
| 部分解决 | 当前源码可重建性 | 本轮源码、测试和文档已分类提交；历史正式二进制继续由归档 hash 对照 | 后续只从 clean commit 构建并把 commit 写入 manifest |
| 外部阻塞 | 原实验机 `/tmp/ab-*.log`、`e1-*.log` | 旧 311->301 us 不能复算 | 用户或实验机提供原始文件 |
| 外部阻塞 | 物理板 | 无法给硬件实时上界 | 获得并配置目标开发板 |

---

## 14. 下一阶段处理顺序

### 阶段 A：先固定证据，不立刻继续长跑

1. [已完成] 将当前 dirty tree 分类提交，固定为可重建源码状态。
2. [已完成] 将过期复现配置修正为只设置 `dedicated_cpus=1`。
3. 收紧现有文档中“改善 7.69%”的措辞，明确它是单次观察值。
4. 给 cyclictest summary 直接增加 P90/P95/P99/P99.9。

验收：后续正式二进制都由明确的 clean commit 构建，且 manifest 记录同一 commit。

### 阶段 B：建立可信基线和测量分解

1. 在修改 WFI 前，先采当前构建至少 3 次 `stress-noiso`/`stress-rt` 重复基线。
2. 增加真正共享 pCPU1 的受控竞争场景，避免无限饿死，可使用有占空比的 host burner。
3. Zephyr 在 30/60 分钟中采多个时间窗口。
4. 开启 realtime trace，记录 source/IRQ、enqueue、notify/IPI、LR inject、Guest ISR。

验收：每个阶段有独立 P50/P90/P99/max，并能用 sequence 1:1 关联。

### 阶段 C：实现 CNTV-only WFI fast path

1. timer profile 明确记录 Guest 实际暴露的 timer 集合。
2. RT Zephyr FDT 只暴露 CNTV；不再把 CNTP 当作可用唤醒源。
3. dedicated + CNTV hardware wake 时清 TWI。
4. 验证 remote vIRQ、VM stop/pause、console input 都能强制退出 hardware WFI。
5. 验收 WFI exit 从约 140/s 降到 0，且无丢唤醒、无停止挂起。

验收：exit 表、阶段 latency 和端到端 Zephyr 数据同时改善，并超过重复实验噪声范围。

### 阶段 D：降低跨分区耦合

将全局 timer wheels 拆成 per-CPU 锁，保留 token owner 和 remote cancel/rearm 语义。

验收：Linux timer 压力不会增加 pCPU1 wheel lock wait；功能回归和正式 trace 通过。

### 阶段 E：最后实现安全抢占

1. 定义 per-CPU `vcpu-context-open` 区间，从 VGIC load 到 save、timer sync 和 deferred
   IRQ token 完成。
2. 在该区间禁止 task switch，只设置 need-resched。
3. 仅在 vCPU loop 稳定边界、deferred work 完成后和 park 前处理抢占。
4. 实现固定优先级 scheduler，FIFO within priority class。
5. 重新接入 coalesced remote IPI，并先修 dedicated startup race。

验收矩阵：`{preempt on/off} x {IPI on/off} x {dedicated on/off} x {SMP4}` 全部通过，
并在低优先级同核干扰任务下证明 wake-to-run 有界。

---

## 15. 当前可以和不可以声称的结论

### 15.1 可以声称

- AxVisor 已支持一个可验证的 dedicated pCPU no-tick 模式。
- Linux 2-vCPU 与 Zephyr 1-vCPU 双 Guest 拓扑可长期运行。
- pCPU1 host periodic tick 在 dedicated 场景严格为 0。
- vIRQ 软件队列容量有界，过载显式 overflow，retry slot 防止已弹 edge 丢失。
- 已修复 Guest console 全局锁阻塞和 `IRQ_ROUTES` 长时全核死锁。
- 四场景正式 1800 秒矩阵和一小时 `stress-rt` 功能稳定性通过。
- native、formal、stability、overload 均有可审计产物和 hash。
- 单次 Zephyr `stress-rt` 相对 `stress-noiso` 观察到 mean/P99/max
  `7.69%/4.46%/4.00%` 的下降。

### 15.2 不可以声称

- 不能声称上述单次差值已经统计显著。
- 不能声称整个系统平均、P90、P99、P99.9 都改善。
- 不能声称固定优先级抢占已经实现。
- 不能声称 dedicated Zephyr 已达到稳态零 VM-exit。
- 不能声称一小时内 Linux 或 Zephyr 长尾分布保持不变。
- 不能声称 Linux Guest `nohz_full` 已生效。
- 不能声称 QEMU TCG 数字是物理硬件的 WCET 或实时上界。
- 不能把缺失的旧 `/tmp` 日志或不可重建 dirty source 当作完整旧/新 A/B。

---

## 16. 证据索引

| 内容 | 路径 |
|---|---|
| 会话事实总结 | [`SESSION-SUMMARY.md`](SESSION-SUMMARY.md) |
| 完整工作日志 | [`WORKLOG.md`](WORKLOG.md) |
| Task1 总索引 | [`README.md`](README.md) |
| 正式矩阵说明 | [`matrix/README.md`](matrix/README.md) |
| 正式四场景 | `matrix/formal-postfix-2026-08-16/` |
| 一小时稳定性 | [`stability/README.md`](stability/README.md) |
| Native Zephyr | `native-zephyr/` |
| vIRQ 过载 | [`overload/README.md`](overload/README.md) |
| CPU/内存/IRQ 分配 | [`allocation-table.md`](allocation-table.md) |
| 锁纪律和死锁 | [`locking-discipline.md`](locking-discipline.md) |
| vGIC maintenance | [`vgic-maintenance.md`](vgic-maintenance.md) |
| 正式设计文档 | [`../../book/design/task1-realtime-design.md`](../../book/design/task1-realtime-design.md) |
| 原始 TODO/评分口径 | `/home/huhu/todo.md` |
| Claude 原始 stdout | `/home/huhu/Library/Application Support/AI Expert Reviews/claude-20260816-082346.Dogd0O/raw-claude-stdout.txt` |

---

## 总结

这 24 小时最有价值的结果，不只是让四个长实验跑通，而是把系统从“遇到 stall 只能猜”
推进到“能够区分 runner、Guest、timer、console、IRQ route、队列和调度问题，并保存可审计
证据”。

代码层面已经具备 RT 分区的多数基础设施；实验层面已经具备正式矩阵、长稳、native 和
过载证据。但原始任务最有分量的两个承诺仍未兑现：**就绪即抢占**和**显著、可信、可重复
的端到端实时性改善**。

下一步不应继续围绕已降为 0 的 host tick 做小修小补，而应先固定证据，再攻击 WFI 软件
wait path 和 timer-wheel 跨分区耦合，最后以安全的 deferred preemption 完成调度主张。
