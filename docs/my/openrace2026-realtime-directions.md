# OpenRace 2026 实时性探索方向总表

更新时间：2026-08-08

本文单独汇总三条正式实时性探索，以及 synthetic vIRQ 的前置激活阻塞。三条正式探索均已完成可复现失败定位，但尚未形成有效的实时性收益 A/B。

| 方向 | 所在链路层次 | 已有修改/实验 | 已确认结果 | 当前阻塞点 | 后续修改可能性 | 处理建议 |
|---|---|---|---|---|---|---|
| `passthrough + runtime trace` | Guest vCPU run → AArch64 entry/host IRQ；绕过软件 timer、vIRQ queue、notify/IPI、pending drain | Axvisor 加入 runtime trace；保留 lower-EL IRQ 单次 dispatch 和 vCPU slice 边界修复 | 双 Guest 可运行，只看到少量 `vcpu_run/guest_exit` | workload 没有经过目标软件层 | 可改 vCPU 运行边界/强制退出，但会进入高风险抢占机制方向 | 只保留为启动/隔离控制组，不作为软件 vIRQ B |
| 共享 pCPU + FIFO/RR | Host scheduler → pCPU affinity → vCPU task → Guest `run()` | 仅改共享 pCPU、FIFO/RR 配置；未改 Axvisor scheduler | FIFO 饿死 Zephyr；RR 仍无 Zephyr 样本 | Guest `run()` 持有 `NoPreempt`，passthrough 长时间不退出，宿主不能抢占 | 修改 vCPU slice、host timer 或安全抢占边界 | 原 FIFO/RR A/B 冻结；只有明确设计抢占机制后才重开 |
| `emulated timer` | Guest CNTV → `arm_vgic`/vtimer → timer wheel → `queue_interrupt` → notify/IPI → wake → drain → inject → Guest IRQ | 做过 PPI27 探针和临时排队 workaround；workaround 已撤销 | 约 30 秒出现 18,493 次未处理 `PPI27/hwirq 27`，无 `PERIODIC LATENCY COMPLETE` | CNTV/PPI27 ownership、level/EOI 生命周期不匹配 | 可在 `arm_vgic`/vtimer 正确实现 level/EOI 归属，并加单次 IRQ 生命周期回归 | 三条中最接近目标软件链路；若继续，优先做语义修复而非排队 workaround |
| synthetic vIRQ 激活（非第四条正式 A/B） | PSCI `CPU_ON` → vCPU secondary first-run → Guest boot params/stage-2 memory；成功后才进入 queue/notify/IPI/drain/inject | 保留 PSCI FDT；尝试 cache sync、架构状态和 CPU_ON 调度修复 | vCPU1 读到 `arm64_cpu_boot_params.mpid=-1`，误走 primary | Guest RAM 可见性、stage-2 属性或目标 pCPU 首次运行上下文未定位 | 可在目标 pCPU first-run 做 GPA/HPA/属性探针，再修复共享内存发布 | 作为 software vIRQ workload 的前置诊断，不计入三条正式实时方向 |

链路关系：

```text
Guest timer/source
  → arm_vgic/vtimer
  → timer wheel（若使用）
  → queue_interrupt
  → notify/IPI
  → vCPU wake/run boundary
  → pending drain/inject
  → Guest IRQ/task
```

`passthrough` 从 Guest vCPU/host IRQ 边界直接进入，绕过中间的软件链路；`emulated timer` 已到达链路中段但卡在 PPI27 ownership/EOI；synthetic vIRQ 还卡在进入链路前的 secondary CPU 启动。因此三者不能共用一组实时性 A/B 数字。
