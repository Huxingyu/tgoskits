# OpenRace 2026：下一阶段执行方法（A → 定位 → B）

> 更新时间：2026-08-08
> A 基线：dbd711396460373d9b54db9e0dfefcbd8a86bad3
> 上一版冻结失败的审计记录见 [openrace2026-todo.md](openrace2026-todo.md)。

本文件是接下来真正执行的方法。不预先指定调度器、timer、GIC、vIRQ 队列或 CPU partition 作为改造对象；先确认实际路径，再用测量证据选择唯一的 B 改造。

## 路径状态：不把淘汰方案重新包装成候选

当前 A 是已经可以运行的 dbd711396 基线；先对它实际可达的层级做 trace。某一层没有被经过也是结果，不应在 trace 之前先换 workload。

| 路径 | 当前状态 | 用途 |
|---|---|---|
| Day5 passthrough + lower-EL host IRQ | 已运行，但不覆盖软件 vIRQ/timer | 作为当前 A 的可达路径和控制组 |
| emulated PPI27 | 已失败，关闭 | 不再修、不再作为 Gate |
| CNTP/PPI30 | 代码支持，但当前 workload 尚未重新证明 | 未验证，不是当前 A |
| synthetic vIRQ | queue/inject API 存在，但缺少已确认的 Guest producer | 未验证，不是当前 A |

接下来先 trace 当前 A 的完整可达层级，再判断是否缺少任务一要求的某个软件层。只有 trace 证明目标层完全未经过时，才单独设计一个最小激活 workload；不是先把旧候选重新列为 A。

## 1. 目标重新定义

任务一不是单纯追求平均延迟更低，而是对 AxVisor 的实时关键路径进行实质改造，使以下至少一项得到可重复改善：

- 端到端中断/唤醒响应的高分位和最大值；
- 周期任务 jitter 尾部；
- 明确定义的 deadline overrun 次数和最大 overrun；
- 压力下的响应稳定性和可预测性。

平均延迟只作为辅助指标。没有分析上的上界证明时，只能宣称“观测窗口内的经验改善”，不能宣称硬实时保证。

主线保持：QEMU AArch64、AxVisor、Linux 2-vCPU、Zephyr 1-vCPU、固定 pCPU/内存/设备配置。passthrough 用于启动、隔离和回归控制；软件 vIRQ/timer workload 必须另外覆盖 AxVisor 软件关键路径。

## 2. 阶段 0：冻结可复算输入

每次实验保存一个 manifest：

    git commit
    Rust nightly / QEMU 版本
    AxVisor feature、VM 配置、interrupt_mode
    Guest 镜像、FDT/DTB、bootargs 哈希
    Linux/Zephyr/workload 版本
    pCPU/vCPU affinity、内存、设备/IRQ 映射
    Host CPU、频率策略、QEMU 参数
    随机种子、周期、相对 deadline、运行时长

A、B 使用同一 manifest；只有目标机制代码或明确的 B 配置可以变化。原始日志、trace、统计结果和 manifest 放在同一实验目录。

## 3. 阶段 1：建立实际路径地图

代码是先验，不是测量结论。下面的链路用于对照运行时 trace，确认当前 A 实际经过和绕过了哪些层。

CNTP/PPI30 的静态候选链：

    Guest CNTP_CVAL/TVAL/CTL
     → arm_vgic vtimer state
     → AxVM timer wheel
     → host timer callback/expire
     → queue_interrupt
     → notify/wakeup + IPI
     → pending interrupt drain
     → GIC/vCPU inject
     → Guest IRQ handler

重点代码：

- virtualization/arm_vgic/src/vtimer/cntp_timer.rs：timer bank、generation、rearm/cancel；
- virtualization/axvm/src/timer.rs：CPU bucket、共享锁、expire、远端 owner rearm；
- virtualization/axvm/src/runtime/vcpus.rs：queue_interrupt、notify、IPI、pending drain；
- AArch64 vCPU/GIC backend：最终注入和 VM entry 前处理。

synthetic vIRQ 至少覆盖 queue_interrupt → notify/IPI → wake → drain → inject，但可绕过 CNTP 和 timer wheel。passthrough 只能作为控制组，不能单独证明软件 vIRQ/timer 改造收益。

当前 A 先产出正式路径声明；CNTP/PPI30 和 synthetic vIRQ 只在 trace 证明需要补充软件层时作为后续激活候选：

| workload | 中断源 | 覆盖模块 | 绕过模块 | 用途 |
|---|---|---|---|---|
| synthetic vIRQ | 软件注入 | queue、notify、IPI、drain、inject | CNTP/timer wheel | vIRQ transport |
| CNTP/PPI30 | Guest physical timer | vtimer、timer wheel 及上述链路 | 视 backend 而定 | timer + transport |
| passthrough | 直通/硬件路径 | 以 trace 为准 | 可能绕过软件 timer | 启动/隔离控制 |
| Native Zephyr | 原生 timer | 无 AxVisor | 全部 AxVisor | Guest-only floor |

静态代码和 runtime trace 不一致时，先检查 feature、VM 配置和 backend，不立即改机制。

## 4. 阶段 2：工具与低扰动观测

### 4.1 工具分工

- perf sched timehist、perf record/report：Linux 侧调度和 CPU 热点；不能替代 AxVisor 内部 trace。
- cyclictest：Linux Guest 周期唤醒参考；不能证明软件 vIRQ 覆盖。
- rtla timerlat：有 Linux rtla 时测 IRQ 到线程的尾延迟；不直接适用于 AxVisor no_std host。
- rtla osnoise、hwlatdetect：区分调度噪声和平台硬件噪声。
- trace-cmd/ftrace 或 eBPF：观察 Linux 侧 sched/IRQ/wakeup。
- AxVisor per-CPU ring trace：必须实现，记录 timer、enqueue、锁等待、IPI、vCPU wake、inject。

### 4.2 AxVisor trace 约束

不得逐样本串口打印。使用固定容量、per-CPU、无分配 ring buffer，测试结束后批量导出。记录：

    trace_version, sequence, event, timestamp, host_cpu,
    vm_id, vcpu_id, correlation_id, queue_depth, status

所有阶段使用同一 counter domain，或记录 host/guest 转换关系。A/B 使用相同 trace 开关；先做 trace off/on 校准，确认观测不改变尾延迟。

必须覆盖：

    T0 guest_release
    T1 host_timer_callback
    T2 timer_expire
    T3 irq_enqueue_begin
    T4 irq_enqueue_end
    T5 notify
    T6 ipi_send / ipi_receive
    T7 vcpu_wakeup
    T8 vcpu_running
    T9 pending_irq_drain
    T10 irq_inject
    T11 guest_irq_entry
    T12 periodic_task_finish

第一版至少覆盖 T3/T4、T5/T6、T7/T8、T9/T11，否则无法区分 queue、IPI、调度和注入成本。

## 5. 阶段 3：A 基线矩阵

短测用于定位：每场景 30 秒、重复 3–5 次。候选 B 冻结后，A/B 至少 30 分钟，最终内部 Gate 1 小时。

| 编号 | 路径 | 负载 | 用途 |
|---|---|---|---|
| N0 | Native Zephyr | idle | Guest-only floor |
| N1 | Native Zephyr | stress | 原生压力参考 |
| A0 | synthetic vIRQ | idle | transport 空载 |
| A1 | synthetic vIRQ | Linux 0/1/2/4 busy worker | transport 压力 |
| A2 | CNTP/PPI30 | idle | timer 空载 |
| A3 | CNTP/PPI30 | Linux 0/1/2/4 busy worker | timer 压力 |
| A4 | CNTP/PPI30 | dedicated CPU + stress | contention 消融 |
| C0 | passthrough | idle/stress | 启动、隔离、回归控制 |

改变一个因素时明确标记为消融，不把不同 workload 的数字直接称为 A/B。

## 6. 阶段 4：指标定义

周期任务第 i 次 release 定义：

    release_i       = 目标释放时刻
    start_i         = 周期任务真正开始执行
    finish_i        = 周期任务完成时刻
    period_i        = release_i - release_(i-1)
    jitter_i        = max(0, start_i - release_i)
    response_i      = finish_i - release_i
    overrun_i       = max(0, finish_i - (release_i + relative_deadline))
    deadline_miss_i = (overrun_i > 0)

漏采样、Guest 卡死、trace 丢失单独统计，不能伪装成普通 deadline miss。当前 scripts/test/rt_latency_stats.py 的 deadline 字段在修正前不能作为最终结论。

中断/唤醒至少报告：

    enqueue_latency = T4 - T3
    notify_ipi      = T7 - T5
    wakeup_latency  = T8 - T7
    inject_latency  = T11 - T9
    e2e_irq         = T11 - T0

每项报告 mean、p99、p99.9、max、样本数、丢失数和异常数。实时结论优先使用 p99.9、max、overrun 和重复实验一致性。

## 7. 阶段 5：选择唯一 B

| 观测结果 | 候选 B | 不应先做 |
|---|---|---|
| synthetic 也有 enqueue/锁长尾 | vIRQ 有界预分配队列或锁临界区 | 先改 CNTP |
| notify/IPI 到 wake 长尾 | IRQ affinity、唤醒目标或通知路径 | 先改 GIC LR |
| wake 到 running 长尾且 stress 放大 | 调度优先级/抢占或 CPU partition | 同时重写 timer |
| CNTP 明显差而 synthetic 正常 | timer owner、rearm、timer wheel | 先改 scheduler |
| dedicated 显著改善共享场景 | CPU placement/隔离 | 宣称硬实时 |
| inject 到 Guest entry 长尾 | GIC/vCPU 注入路径 | 先改 workload |

B 必须写清问题证据、单一机制、替代方案、非目标、回滚方式和预期指标。没有对应 trace 区间的改动不进入 B。

## 8. 阶段 6：同口径 A/B

1. 同一 commit 基线、镜像、QEMU、DTB、配置和 pCPU affinity；
2. 同一 workload、周期、relative deadline、stress worker 数和时长；
3. trace 开关、统计脚本和导出方式相同；
4. A/B 交替运行，避免机器状态偏差；
5. 至少 3 次独立重复，报告每次原始结果及汇总；
6. 同时报告 mean、p99、p99.9、max、overrun、CPU 负载、队列深度和功能错误。

“B 平均值更低”不构成通过；目标尾部指标改善且无严重退化才算有效。

## 9. 阶段 7：长稳与交付 Gate

短测通过后才做长稳：30 分钟初验、1 小时最终 Gate。Linux 2-vCPU、Zephyr 周期任务和 stress 同时运行，检查 panic、Guest 卡死、IRQ 重入、队列溢出、DMA quarantine、串口丢失和 trace 丢失，并保存原始日志、trace、manifest、统计脚本和 SHA256。

任务一完成条件：

1. AxVisor 软件路径由代码和 trace 双重确认；
2. Native / A / B 完成 idle + stress 对比；
3. 调度延迟、中断响应、周期 jitter、p99.9、max 和 overrun 有数据；
4. B 至少一个实时尾部指标可重复改善，无未解释的严重退化；
5. 长稳和复现材料齐全；
6. 文档明确不宣称硬实时保证、不把 passthrough 冒充软件 vIRQ 收益、不把 PPI27 workaround 当 Gate。

## 10. 立即执行顺序

1. 为当前 A 建立 manifest，并标记现有 passthrough/lower-EL 路径；
2. 对当前 A 做分层 trace，记录实际经过、绕过和不可观测的层；
3. 只有目标软件层缺失时，才设计最小激活 workload，并先做一次 smoke；
4. 修正统计脚本的 deadline/overrun 定义，完成当前 A 的短基线；
5. 根据分段 p99.9/max 只选一个 B；
6. 为 B 添加确定性回归测试，完成 fmt、clippy 和同口径 A/B；
7. 短测通过后做 30 分钟，再做 1 小时长稳；
8. 最后更新任务一设计、测试报告和提交材料。

第 2 步完成前，不重新启用 PPI27，不把 CNTP/PPI30 或 synthetic vIRQ 称为当前 A，也不提交第二个实时机制改造。
