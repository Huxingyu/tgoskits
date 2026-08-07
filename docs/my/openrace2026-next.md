# OpenRace 2026：当前下一步

> 更新时间：2026-08-08
> 当前基线：`dbd711396460373d9b54db9e0dfefcbd8a86bad3`

本文件只保留未来 1–2 天要执行的事情。赛题原文、完整里程碑、历史结果和最终验收条件统一放在 [`openrace2026-todo.md`](openrace2026-todo.md)，不在这里重复维护。

## 当前目标

完成任务一的 A 阶段：在不新增实时机制改造的前提下，测量一条真正经过 Axvisor 软件路径的中断/唤醒链路，并冻结可复算的未改造基线。

当前不是任务一完成状态，也不开始任务二网络或任务三 AI 扩展。

## 已冻结条件

- 平台：QEMU AArch64 + Axvisor。
- Guest：Linux 2-vCPU（pCPU 1、2）+ Zephyr 1-vCPU（pCPU 3）。
- `passthrough`：只作为 Linux 启动、双 Guest 隔离和无回归控制组。
- 软件路径：优先使用已有正确语义的 CNTP/PPI30 或 synthetic vIRQ workload；PPI27 不作为 Gate。
- A/B 口径：当前提交是 `A`；完成测量后只选一项机制形成 `B`。

## 执行顺序

1. 确认 workload 覆盖 Axvisor 的软件 vIRQ、timer 或 vCPU 唤醒路径。
2. 加入低扰动观测：事件产生、enqueue、锁等待、IPI、vCPU 唤醒、vIRQ 注入、Guest 响应。
3. 运行 A 基线：Native Zephyr、Axvisor Linux idle、Axvisor Linux stress，以及软件路径 workload；短测 30 秒，重复 3–5 次。
4. 统计周期 jitter、调度/中断响应延迟、p99、p99.9、max、overrun、CPU 负载和队列深度。
5. 根据数据只选择一个 B 改造点，写清问题、替代方案、预期收益和回滚方式。

## A 阶段完成条件

- workload 确实经过目标 Axvisor 软件路径，而不是只经过 `passthrough`；
- A 的原始日志、trace、配置、命令和统计结果已保存；
- 至少一个瓶颈有可复核的测量证据；
- 没有因为观测日志改变 workload 的实时行为；
- 在 A 完成前不提交第二个实时机制改造。

## 当前不做

- 不继续追 PPI27 的临时 level/EOI workaround；
- 不同时改调度器、timer、vIRQ 队列和锁；
- 不把 `deadline_misses=300` 当作实时失败结论；
- 不切换 StarryOS，不开始网络协议和 AI 闭环；
- 不进行最终 30 分钟/1 小时长稳，直到 A/B 机制冻结。

## 完成后切换

A 阶段满足条件后，回到 [`openrace2026-todo.md`](openrace2026-todo.md) 的“下一阶段：A 基线测量与 B 改造”，实施 B 并做同口径 A/B。
