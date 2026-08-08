# 项目分析及文档说明

**Session ID:** ses_0201d1c13ffe77iI9YG24yXWOy
**Created:** 8/8/2026, 1:40:16 PM
**Updated:** 8/8/2026, 2:29:12 PM

---

## User

你来分析一下这个项目吧,结合文档进行一个说明

---

## Assistant

我来分析这个项目。先看一下项目结构和文档。

**Tool: read**

**Tool: glob**

**Tool: bash**

---

## Assistant

**Tool: read**

**Tool: read**

---

## Assistant

**Tool: bash**

**Tool: bash**

---

## Assistant

**Tool: bash**

**Tool: bash**

---

## Assistant

**Tool: bash**

**Tool: bash**

---

## Assistant

**Tool: read**

**Tool: read**

---

## Assistant

**Tool: bash**

**Tool: bash**

---

## Assistant

# TGOSKits 项目分析

## 项目定位

TGOSKits 是 **rcore-os** 组织的 Rust 操作系统与虚拟化集成工作区（Apache-2.0，Rust 2024 Edition，约 184 个 workspace 成员、146+ crate）。它的边界不是单一 OS 发行版，而是**系统软件组件的开发、组合和跨系统验证环境**——把可独立演进的 crate 与完整系统放进同一个 workspace，通过 Git Subtree 汇聚了 ArceOS、StarryOS、Axvisor 三个原本独立的仓库。

## 三种系统形态（`os/`）

| 系统 | 定位 | 说明 |
|------|------|------|
| **ArceOS** | 模块化 Unikernel | 最底层基础，12 个内核模块（axhal/axtask/axmm/axfs-ng...）+ API 聚合层（arceos_api、posix_api）+ 用户态库（axstd、axlibc），是另外两套系统的共同依赖 |
| **StarryOS** | Linux 兼容内核 | 基于 ArceOS，组件化实现 Linux syscall 语义（进程、文件、信号、网络、IPC），支持 Alpine rootfs 完整用户态执行，测试分 normal/stress 两组 |
| **Axvisor** | Type-I Hypervisor | 多 Guest（Linux/ArceOS/RT-Thread/Nimbos），ARM vCPU/VGIC、RISC-V vCPU/vPLIC、x86 vCPU/vLAPIC，板级 + VM 双层 TOML 配置 |

## 仓库分层（五层架构）

文档定义了严格的依赖方向，上层只能通过能力边界用下层资源：

1. **系统产品层** `os/` — 三套系统的组装代码
2. **系统能力层** — syscall/进程、运行时/调度、VM/vCPU、OS Glue
3. **共享组件层** — `components/`（调度、同步、进程、信号）、`memory/`（分配器、页表、dma-api/mmio-api）、`virtualization/`（axvm、vCPU、vgic）、`drivers/`（rdif-* 接口 + 块/网/中断/总线/SoC 驱动）
4. **平台层** `platforms/` — 启动、固件交接（someboot）、动态平台（axplat-dyn）
5. **驱动层** — 通过 MMIO/DMA/IRQ 契约控制实际设备

支撑 4 种 64 位架构（AArch64、RISC-V64、x86_64、LoongArch64），支持静态板卡和基于 FDT/ACPI/UEFI 的动态平台。

## 工程体系

- **统一命令入口**：`cargo xtask`（快捷别名 `cargo arceos` / `cargo starry` / `cargo axvisor`），底层由 `scripts/axbuild` 做配置解析和构建编排；板卡配置存于各系统 `configs/board/*.toml`
- **验证三层级**：Host（`cargo xtask test` + clippy 白名单）→ QEMU（完整镜像系统测试）→ 物理板卡（`cargo xtask board`，self-hosted runner，含 OrangePi-5-Plus 等）
- **测试套件** `test-suit/`：arceos（Rust+C 用例）、starryos（normal/stress）、axvisor（QEMU/U-Boot/板卡）
- **文档体系**：Docusaurus 站点（`docs/`）+ 设计文档（`book/design/`）+ 开发规范（`book/guideline/`，如 code-quality、feature-development、starry/syscall）

## 当前状态

最近提交显示正在做 **openrace 实时性相关探针**（realtime probe、合成 virq smoke 测试、axvm PSCI/FDT 生成等），主线分支为 `dev`，另有竞赛分支 `contest/quancheng-axvisor-2026`。

---

## User

你来看一下现在的赛题1吧,说一下你的思路

---

## Assistant

**Tool: bash**

**Tool: grep**

---

## Assistant

**Tool: bash**

**Tool: read**

---

## Assistant

**Tool: read**

**Tool: read**

---

## Assistant

**Tool: read**

**Tool: read**

---

## Assistant

**Tool: read**

**Tool: bash**

---

## Assistant

让我快速看一下相关核心代码，以便给出有依据的思路。

**Tool: bash**

**Tool: grep**

---

## Assistant

# 赛题 1（实时性改造）现状盘点与我的思路

## 现状速览

| 项 | 状态 |
|---|---|
| 时间 | 今天 8/8，攻关截止 8/20，提交 8/21–24 —— 只剩 **12 天** |
| 基线 A | `dbd711396`：QEMU AArch64、AxVisor、Linux 2-vCPU（SMP 启动 OK）、Zephyr 1-vCPU 周期采样器（10ms/300 样本），Native QEMU vs AxVisor 双基线已有 |
| 已做改造 | lower-EL host-IRQ 单次 dispatch（有回归测试，**无 A/B 数据**）；FDT bootargs 修复 |
| 冻结方向 | passthrough+trace（没走软件 vIRQ 链路）、共享 pCPU FIFO/RR（`NoPreempt` 饿死）、emulated PPI27（CNTV 未处理 IRQ）、synthetic vIRQ（vCPU1 `mpid=-1` 误走 primary） |
| **未启动** | 任务二（IP 通信，25 分）、任务三（AI 闭环，25 分）、视频/PR/文档 |

## 我的判断：三个核心问题

**1. 时间配置与分值严重失衡。** 任务一剩余可拿分 = 实质改造 8 + 改造前后数据 5 + stress 对比 4（空载/压力部分已有）≈ **13–17 分**，而且卡在"没有任何一条经过软件 vIRQ 链路的可用 workload"上——三条探索加 synthetic 全被冻结，说明问题不是"选哪个 B"，而是 **emulated 路径整体没打通**。而任务二 + 三共 50 分还一笔没动，且任务三依赖任务二的协议。

**2. 任务一的真正瓶颈是"无路可测"，不是"没有改造点"。** 没有 workload 经过 `queue_interrupt → notify/IPI → wake → drain → inject`，任何 B（timer 锁、调度、IRQ affinity）都无法形成 A/B 数据。解锁路径只有两条：修 CNTV/PPI27 的 level/EOI 语义（day5 已定位到 arm_vgic/vtimer 归属问题），或修 synthetic vIRQ 的 secondary boot（`mpid=-1`）。

**3. next.md 的 trace-first 方法论正确，但对 12 天太奢侈。** 再花几天 trace + 再赌一个 workload 激活方向，风险是又走三天死胡同。

## 我的建议思路

**给任务一设硬期限：3–4 天内出一次有效 A/B，主攻 CNTV/PPI27 level-EOI 语义修复。** 它一石二鸟：本身是"定时器/中断路径"的实质改造（8 分项），又能解锁整条软件 vIRQ 测量链路。失败标准要提前写死——若 PPI27 修不通，立即降级方案：在 **passthrough 下做"vCPU 时间片/抢占边界"改造**（已有 `bound vcpu slices at handled exits` 的基础，slice 机制是真实存在的调度改造点），用 Zephyr 尾延迟直接做 A/B，数据照样完整。

**立即并行启动任务二（不等任务一）。** 最短路径：两张 virtio-net 直通 + QEMU tap/hub 桥接，Linux ↔ Zephyr 用简单 UDP 协议（版本/类型/长度/序号/校验），可靠性用 seq+ACK+超时重传。这是 25 分里性价比最高的部分，配置型工作，风险低。

**任务三用最成熟的组合：** Linux 里跑一个小 CNN/onnxruntime 推理 → 通过任务二协议发控制量 → RTOS 驱动虚拟外设（LED/PWM 计数），端到端延迟用协议时间戳测。4 天内可出演示闭环。

**加分项（StarryOS +4 分）放到主线全通之后**，别在只剩 12 天时换主客户机。

要不要我先帮你把任务二的最小网络拓扑/配置和任务一的 PPI27 修复探针列成具体执行清单？

---

## User

@docs/my/openrace2026-realtime-directions.md 你来具体的分析一下,我们是哪里出现了问题,导致这几条路都没有走通呢?

---

## Assistant

我来深入代码分析这几条路各自卡在哪。先并行读关键实现。

**Tool: read**

**Tool: read**

---

## Assistant

**Tool: bash**

**Tool: grep**

---

## Assistant

**Tool: read**

---

## Assistant

**Tool: read**

**Tool: read**

---

## Assistant

**Tool: read**

**Tool: read**

---

## Assistant

再看两个关键点：sysreg 的 CNTV/CNTP 处理 和 PSCI CPU_ON 路径。

**Tool: read**

**Tool: read**

---

## Assistant

**Tool: grep**

**Tool: grep**

---

## Assistant

**Tool: read**

**Tool: bash**

---

## Assistant

最后确认 `vcpu.rs` 的 NoPreempt/slice 机制和 arm_vcpu 的 timer trap 配置。

**Tool: read**

**Tool: bash**

---

## Assistant

代码看完，四条路的根因其实都清楚。先给整体机制，再逐条拆。

## 关键机制（根因分析的坐标系）

```text
vcpu_run 循环
 ├─ run_vcpu → with_current_cpu_set {   ← 持有 NoPreempt + CPU pin（vcpu.rs:303）
 │    drain 中断 → vcpu.run()           ← guest 一直跑，直到 VM-exit
 │    handle_vcpu_exit_bound            ← handled exit 结束 slice，释放 NoPreempt
 ├─ ... 循环
```

- **CNTP**（物理 timer，PPI30）有完整软件模拟：`arm_vgic/src/vtimer/`，触发走 `queue_virtual_interrupt(PPI30)` → timer wheel → queue → notify/IPI → drain → inject（cntp_timer.rs:370）
- **CNTV**（虚拟 timer，PPI27）：`arm_vcpu/vcpu.rs:241-266` 里只设置了 `CNTHCTL_EL2.EL1PCEN/PCTEN`（管 CNTP），**HCR_EL2.TCV 从未设置**（管 CNTV trap）——**CNTV 永远直通硬件，任何模式都没有软件模拟**

## 逐条根因

### ① passthrough + trace：工具选错，不是 bug
`passthrough` 模式三连直通：`CNTHCTL_EL2` 置位（CNTP 不 trap）、TCV 未设（CNTV 不 trap）、不设 `HCR_EL2.IMO/FMO`（物理 IRQ 不进 EL2）。Guest 的定时器和中断**全部由硬件直接处理**，AxVisor 软件层（queue/notify/IPI/drain/inject）在设计上就不可能被经过。trace 只看到 `vcpu_run/guest_exit` 是必然结果，它只能当启动/隔离控制组。

### ② FIFO/RR：架构性缺失，不是配置问题
Guest `run()` 全程在 `NoPreempt` + CPU pin 里（vcpu.rs:303），而 passthrough 下 guest 长时间不 VM-exit（没有软件 timer 强制打断），slice 永远不结束 → **宿主调度器被锁死**。AxVM 的 vCPU 调度本质是"exit 驱动的协作式"，根本没有时间片抢占机制，改 FIFO/RR 配置是空中楼阁。这条要通必须先造"强制退出边界"。

### ③ emulated PPI27：功能缺口，这是最值得修的一条
链条：
1. Zephyr 的系统 tick 用 **CNTV（PPI27）**，而 AxVM 只模拟了 **CNTP（PPI30）**
2. 因为 TCV 未设置，Zephyr 写 `CNTV_CTL/CVAL` 直接落在硬件上，**AxVisor 不知情、也没有软件状态**
3. emulated 模式设置 IMO → CNTV 硬件触发时 IRQ 27 作为 `ExternalInterrupt{vector:27}` trap 到 EL2
4. AxVM 把它当 **host IRQ** 处理（mod.rs:215 `AlreadyHandled` → `check_timer_events()`）→ timer wheel 里根本没有对应事件 → **无人消费**
5. 硬件 CNTV 状态没人清 → level 触发再触发 → 18,493 次风暴；guest 也永远收不到注入 → 没有 `PERIODIC LATENCY COMPLETE`

day5 的 workaround 失败同理：注入一次后没有"清 CNTV 状态 / 等 guest 重新编程"的闭环，level 语义立刻再次触发（~100µs 周期）。文档写的"ownership/level-EOI 不匹配"是这个缺口的表象，**真因是 CNTV 系完全没有被虚拟化**。

### ④ synthetic vIRQ：卡在了与实时性无关的前置
`arm64_cpu_boot_params.mpid=-1` 是 **secondary CPU 共享内存发布问题**：primary 写入 boot_params 与 vCPU1 在另一 pCPU 上读取之间，缺 cache 维护/内存屏障/正确的 stage-2 属性。注意 `ArchOps::clean_dcache_range` 默认是 **no-op**（ops.rs:43-44），AArch64 虽实现了，但写入侧是否调用是另一回事。而且它离实时性链路太远——**synthetic vIRQ 根本不需要 secondary CPU**：缺的只是 "Guest producer"（guest 侧一个 MMIO 写触发 `queue_interrupt`），单 vCPU 就能打通 queue→notify→IPI→wake→drain→inject 全链，把时间花在 CPU_ON 上跑偏了。

## 总结

| 方向 | 问题性质 | 是否可救 |
|---|---|---|
| ① passthrough+trace | 配置性：设计上绕过软件层 | 否，仅控制组 |
| ② FIFO/RR | 架构性：无抢占机制 | 高风险大改造 |
| ③ emulated PPI27 | **功能缺口：CNTV 未虚拟化** | **是，最接近目标** |
| ④ synthetic vIRQ | 前置障碍：secondary 内存发布 | 可绕过（不需要双 vCPU） |

真正该做的是 ③ 或 ④ 的绕过版：要么补 CNTV 软件模拟（TCV trap + CNTV sysreg 设备 + PPI27 路由，一石二鸟——既是"定时器/中断实质改造"的 8 分项，又解锁整条软件链路），要么做一个**单 vCPU 的 MMIO 触发软件注入** workload，先把 `queue→notify→IPI→drain→inject` 的测量打通拿 A/B 数据。

---

## User

这里的1/2是架构属性是吗?

---

## Assistant

是的,但两者性质略有不同,都**不是 bug 或配置错误**,而是架构层面的属性:

**① passthrough 是"设计属性"**——故意为之。passthrough 的定义就是绕过软件虚拟化层让硬件直通:CNTP/CNTV 不 trap、物理 IRQ 不进 EL2。所以 workload 不经过软件 vIRQ 链路是这个模式的**预期行为**,不是缺陷。它天然只能当控制组。

**② FIFO/RR 是"架构缺口"**——不是设计选择,而是**当前架构没有这个能力**。AxVM 的 vCPU 调度是"exit 驱动的协作式":guest `run()` 持 `NoPreempt` + CPU pin,只有 VM-exit 才释放。FIFO/RR 调度器配置存在,但**没有任何机制能让一个 guest 在运行中被强制退出**——没有 host timer 打断、没有 slice 到期检查。所以调度器参数改什么都没用。这不是说架构上不可能(KVM 都有 vCPU 抢占),而是当前 AxVM 没实现这个机制,属于"缺失"而非"有意不做",改它需要设计一个强制退出边界,风险高。

一句话区分:
- ① = **故意绕过**(不是问题)
- ② = **机制缺失**(是问题,但改造风险大)
- ③ = 功能缺口(CNTV 没被虚拟化)——最值得修
- ④ = 前置障碍(内存发布),且本可绕过

---

## User

那么除此之外,以你看代码的分析,以及我的trace记录,还有哪些值得修的可以提高实时性的东西呢,深入研究一下吧

---

## Assistant

我先看 trace 数据和相关代码路径,再深入分析。

**Tool: bash**

**Tool: bash**

---

## Assistant

**Tool: bash**

**Tool: bash**

---

## Assistant

**Tool: bash**

---

## Assistant

**Tool: bash**

**Tool: read**

---

## Assistant

**Tool: bash**

**Tool: grep**

---

## Assistant

**Tool: read**

**Tool: read**

---

## Assistant

**Tool: read**

**Tool: read**

---

## Assistant

**Tool: bash**

**Tool: read**

---

## Assistant

**Tool: read**

**Tool: bash**

---

## Assistant

**Tool: bash**

**Tool: bash**

---

## Assistant

**Tool: bash**

**Tool: bash**

---

## Assistant

**Tool: bash**

**Tool: bash**

---

## Assistant

**Tool: bash**

---

## Assistant

**Tool: bash**

---

## Assistant

研究完了。我把代码里所有值得修的实时性点系统梳理出来——大部分都集中在**软件 vIRQ 传输链路**和**timer wheel** 上,恰好就是你还没打通的那条路。

## 值得修的实时性点(按链路)

### A. vIRQ 传输链路(runtime/vcpus.rs + runtime/dispatcher.rs + runtime/queue.rs)

**A1. `queue_interrupt` 无条件 `notify_all()` + `send_ipi()`** — `runtime/vcpus.rs:119-125`
```rust
runtime.queue_interrupt(vcpu_id, vector)?;   // 只 push 了目标 vCPU 一个中断
runtime.notify_all();                        // 唤醒 VM 所有 vCPU waiter!
crate::host::task::send_ipi(cpu_id);         // 无条件发 IPI,即使目标正在跑
```
三个问题:
- `notify_all` 唤醒所有 vCPU(惊群,非目标 vCPU 白醒一次)
- **目标 vCPU 若正在 guest 里运行(未等待),这个 IPI 完全多余**——drain 本来就在下次 entry 前做
- 反之若目标在等待,IPI 是必要的(否则没人叫醒它)

这就是经典 **doorbell 优化**:只在目标 vCPU 处于 wait 状态时发 notify/IPI,正在运行时完全跳过。直接压 `enqueue→inject` 延迟和 IPI 次数,是"中断/唤醒响应"评分点的实质改造,可测(比较 IPI 计数和 e2e_irq 尾延迟)。

**A2. enqueue 路径串行三个锁 + 迁移窗口** — `dispatcher.rs:109-127`,`vm/mod.rs:287-300`
`lookup_cpu_id`(锁1)→ `queue.push`(锁2)→ caller `notify_all`(wait queue 锁3)→ `send_ipi`。锁之间任务可能迁移,IPI 发到旧 CPU → 要等下一次调度才交付 → **延迟尾的直接来源**。且注意 `vm/mod.rs:287` 的老路径 `queue_interrupt` 还在用 `pending_interrupts` + `vcpu_task_list`,和新 `irq_dispatcher` 是**两套并行机制**,arm_vgic 现在走的是哪条要确认,双写是复杂度来源。

**A3. drain 每次 `Vec` 全量分配** — `queue.rs:58-64`:每次 vCPU entry 前 `drain` 都做一次 alloc。中断密集时每 entry 一次堆分配+释放。**换成固定容量 per-vCPU 的 SPSC ring buffer**(中断是单生产者——timer 回调/设备回调,单消费者——vCPU entry)是无分配路径,锁都省了。这正是文档里"vIRQ 有界预分配队列"的方向。

**A4. GIC LR 注入 panic 风险** — `gic.rs:75-79`:LR 满且同 vector 不在 LR 时直接 `panic!("no free list register")`。高 IRQ 率(比如 18,493 次 PPI27 风暴)下一旦 LR 占满就 panic,实时系统不可接受。应改排队到 software pending 而不是 panic。

### B. Timer wheel(timer.rs)

**B1. 全局单锁 + 每事件 NoPreempt** — `timer.rs:112, 226-235`:所有 CPU 共用一个 `SpinNoIrq<TimerWheels>`,`check_events` 里每个 expire 事件都重新抢全局锁。per-CPU bucket 有了,但锁还是全局的。CNTP 每 guest tick 的 cancel+register 都是全局串行点。**per-CPU wheel + 分离锁**是直接对应"定时器"评分点的改造。

**B2. 远端 rearm 同步跨 CPU 阻塞** — `timer.rs:192-202`:`run_on_cpu_sync` 到 owner CPU;若 owner 正跑 guest(NoPreempt 持有),**调用方一直等到它 VM-exit**。这是跨 CPU timer 尾部延迟的潜在最大头。失败 fallback 只发 IPI 不重设 timer → 可能丢 rearm。可改异步/非阻塞。

**B3. 空 wheel park 1 秒 + 无条件重设 oneshot** — `timer.rs:205-212`:empty wheel 把 host timer park 到 1s 后(还是会在 1s 时空触发一次);每次 register 即使 deadline 未提前也重设 host timer。低负载时纯浪费,高负载时是 tick 源。

### C. vCPU 运行边界

**C1. affinity fallback 静默降级** — `vcpus.rs:434-461`:请求的 pCPU mask 与 enabled mask 无交集时,`fallback_mask = isolate_lowest_one()` **把 RTOS vCPU 悄悄挪到别的核**,只 warn。实时确定性被破坏却没有显式失败。应改显式 error,这个改动最小、正确性收益最大。

**C2. passthrough vCPU 无 slice 强制退出**(你已冻结的 ② 的正解):ArceOS 的 preempt 机制其实**存在**——`scheduler_timer_tick` 设 preempt_pending,`NoPreempt` drop 时检查并 resched(`run_queue.rs:711-800`)。passthrough 下 guest 不 exit → NoPreempt 不释放 → pending 永远不生效。**解法不是改 scheduler,而是给 vCPU 加 host oneshot timer → 到期强制 VM-exit → 释放 NoPreempt 的 slice 机制**(KVM 的 preempt-timer 同款思路)。这是把 ② 从"死路"变"实质调度改造"的唯一正路,而且和 A/B 评分点"调度/抢占"直接对应。

### D. 测量环境本身(你的 trace 数据解读)

**D1. 串口共享是抖动源**:day5 数据 mean jitter ~250µs,但 Zephyr 采样器每 10ms 打一行 CSV,Linux 日志同串口——115200 波特率下一行 ~100µs,冲突时直接进尾延迟。**trace 采集本身要改 ring buffer 批量导出(你 next.md 已规划),但当前数据里串口是最大噪声,基线对比前应先分离**。

## 优先级建议

| 优先级 | 项 | 对应评分点 | 风险 |
|---|---|---|---|
| P0 | A1 doorbell(A2 一并做) | 中断/唤醒响应 | 低,纯增益 |
| P0 | C1 affinity 显式失败 | 确定性/配置合理 | 极低 |
| P1 | A3 无锁 SPSC 队列 | vIRQ 传输 | 中 |
| P1 | B1/B2/B3 timer wheel | 定时器 | 中 |
| P1 | C2 vCPU slice 强制退出 | 调度/抢占 | 高(但你已冻结,可重开) |
| P2 | A4 LR 不 panic | 稳定性 | 低 |

P0 两项改动小、是纯粹的确定性改造,而且**正好可以作为"改造前后"数据的最小 B**:在 emulated/synthetic 链路打通后,先做 A1+C1 拿第一组 A/B,再决定是否碰高风险的 C2。要我先从 A1 开始出具体实现方案吗?

---

## User

我们刚才说的方向3是什么优先级呢?

---

## Assistant

方向3(CNTV 未虚拟化)不是普通改造点,它是**所有实时性改造的前置解锁条件**——没有它,优先级表里所有 A/B 项都无法形成有效数据。所以它排在最高:

## 全局优先级修正

| 序 | 项 | 性质 | 作用 |
|---|---|---|---|
| **P0-前置** | **方向3:打通软件链路** | 解锁条件,非最终改造 | 没有它,A1-B3 全测不了 |
| P0 | A1 doorbell + A2 锁精简 | 改造点(中断/唤醒) | 第一个可测的 B |
| P0 | C1 affinity 显式失败 | 改造点(确定性) | 顺手做 |
| P1 | A3 SPSC 队列 / B1-B3 timer | 改造点 | 链路打通后测 |
| P1 | C2 vCPU slice 强制退出 | 改造点(调度/抢占) | 高风险,最后 |

## 但方向3内部要分两条路,有成本差

1. **完整修 CNTV**(HCR_EL2.TCV trap + CNTV_CTL/CVAL sysreg 设备 + PPI27 路由)——改动面跨 arm_vcpu + arm_vgic + axvm,是"定时器实质改造"的正主,评分含金量高,但 12 天风险大
2. **绕过版:单 vCPU MMIO 触发 synthetic vIRQ**(guest 写一个测试设备的 MMIO → handler 调 `queue_virtual_interrupt`)——只需要一个 guest producer,一天内可通,能立刻测 A1/A2/A3(纯 vIRQ 传输),**但测不了 B1-B3(timer wheel)**

## 我的建议顺序

- **先走绕过版**把 A 组改造(尤其 A1 doorbell)拿到 A/B 数据——这是 12 天内最有把握的"实质改造 + 数据完整"
- **CNTV 完整修复作为并行的第二主线**,成功了就补上 B 组(timer)的改造和"定时器路径"评分点;失败了已有 A 组数据保底
- 两条路共用同一个 trace/统计体系,不冲突

一句话:**方向3 = P0,但走"先绕过、后完整修"的降险策略,它是所有改造的入口,不是改造本身。** 要我先做绕过版的 guest producer 设计吗?

---

## User

值得改造对吧?讲一下你的改造的思路吧,一个大致的todo,和测试,如何测试它已经被修改完成了呢?

---

## Assistant

方向3值得改造,而且它就是整个实时性工作的解锁钥匙。让我先把参照代码确认清楚,再给出完整方案。

**Tool: read**

**Tool: read**

---

## Assistant

**Tool: bash**

**Tool: bash**

---

## Assistant

**Tool: bash**

**Tool: bash**

---

## Assistant

**Tool: bash**

**Tool: bash**

---

## Assistant

方向3值得改造——它是把整条软件 vIRQ 链路(你能测所有 A/B 的前提)解锁的关键,而且改造本身就是"定时器/中断路径实质改造"的评分点。我把方案设计好了,基于代码现状给出完整计划。

## 改造思路(设计)

**核心洞察**:`CntpTimerState`(CNTP/PPI30)已经实现了一个完整、有测试的软件 timer bank。CNTV 与 CNTP 的差别只有三处:

| 项 | CNTP(已有) | CNTV(缺失) |
|---|---|---|
| counter 源 | `CNTPCT_EL0`(物理) | `CNTVCT_EL0`(虚拟,EL2 下读就是 guest 视角,CNTVOFF 自动生效) |
| PPI | 30 | 27 |
| trap 开关 | `CNTHCTL_EL2.EL1PCEN/PCTEN`(emulated 时已 trap) | **`HCR_EL2.TCV` 从未设置** ← 根因 |

所以**不是写新逻辑,而是把 `CntpTimerState` 泛化成通用 bank**(`vm_id, vcpu_id, ppi, counter_fn` 参数化),CNTP/CNTV 各实例化一个。工作量集中在三处:

1. **`arm_vcpu/vcpu.rs:258`**:emulated 模式补 `HCR_EL2.TCV`(CNTV_CTL/CVAL/TVAL trap 到 EL2);`CNTVCT_EL0` 保持直通(`EL1VCTEN=1`),guest 读时间戳零开销,也避免改动 `aarch64_sysreg`(它没有 CNTVCT 枚举)
2. **`arm_vgic/vtimer/`**:泛化 bank + 新增 `SysCntvCvalEl0/SysCntvCtlEl0/SysCntvTvalEl0` 三个设备(参照 cntp 系列,`SystemRegType::CNTV_*_EL0` 已在 0x30f806/0x32f806/0x34f806 存在),fire 时 `queue_virtual_interrupt(PPI27)` 走现有 `queue→notify→IPI→drain→inject` 链
3. **`axvm/arch/aarch64/vtimer.rs`**:`Aarch64VtimerFactory` 的 bundle 同时注册 CNTP + CNTV 设备

**level 去重是关键语义**:CNTV 是 level 触发。必须在 bank 里记录 fired 状态——注入一次后,若 guest 未重新编程(改 CVAL/CTL)就不再注入;guest 重新编程时复位。否则就是 day5 的 ~100µs 重复风暴。CNTP 现有实现没有这个(它靠 generation 防 stale 回调,但没有 level 去重),泛化时一并补上。

## TODO

```text
[ ] T1  arm_vcpu:emulated 时设置 HCR_EL2.TCV + 确认 EL1VCTEN 直通 CNTVCT
[ ] T2  arm_vgic:泛化 TimerBank(parameterize ppi/counter_fn)+ level-fired 去重
[ ] T3  arm_vgic:新增 CNTV_CTL/CVAL/TVAL 三个 sysreg 设备(共享 bank)
[ ] T4  axvm:vtimer factory bundle 注册 CNTV 设备
[ ] T5  回归:CNTP 行为不变(现有 156+ 测试全过)
[ ] T6  回归:CNTV bank 单测(参照 cntp_timer.rs 测试模式)
[ ] T7  QEMU emulated 冒烟:Zephyr 出 PERIODIC LATENCY COMPLETE,零 PPI27 风暴
[ ] T8  双 Guest emulated:Linux 2-vCPU + Zephyr,不回归 passthrough 主线
[ ] T9  A/B:emulated(改造后)vs passthrough(控制组)+ Native 基线,30min×3
[ ] T10 长稳 1h + 数据归档 + 设计文档
```

## 如何验证"改完了"(每层判据)

**单元层(T2/T3/T5/T6)**:host-test 单测断言
- CNTV bank:写 CVAL+EN → `fire_target() == Some((vm, vcpu, 27))`;fire 后不改状态 → 不再触发(level 去重);重新写 CVAL → 可再次触发;IMASK/禁用 → 不触发
- 现有 CNTP 测试一个不改、全绿(证明泛化无回归)

**架构层(T1)**:`cargo check -p axvm --target aarch64-unknown-none-softfloat` + 反汇编/日志确认 TCV 位生效(guest 写 CNTV_CTL 产生 `SysRegWrite` exit,日志可见 `aarch64-cntv-ctl-el0` 设备命中)

**集成层(T7)**:emulated 模式跑 Zephyr 周期采样器,判定:
1. 出现 `PERIODIC LATENCY COMPLETE samples=300`(之前永远没有)
2. 未处理 `PPI27/hwirq 27` 计数为 **0**(之前 18,493)
3. trace 出现完整链 `irq_enqueue_begin → enqueue_end → vcpu_notify → host_ipi_send → pending_irq_drain → guest_irq_entry`——即 T3~T11 全链路证据,这是之前任何一条路都没有的

**对比层(T9/T10)**:同一 manifest(镜像/QEMU/affinity 全冻结)下 emulated-vs-passthrough 的 p99.9/max/deadline-miss;A/B 交替跑;30min×3 后 1h 长稳。达标线:软件链路数据完整 + 无退化 + 长稳无 panic/队列溢出。

要我现在从 T1/T2 开始动手吗?T2 的 bank 泛化会动到 `cntp_timer.rs` 的核心,建议先做 T1 验证 TCV 实际生效路径,再泛化。

---

