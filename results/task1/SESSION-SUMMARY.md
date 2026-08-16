# Task1 Session 总结：实时 RTOS 化改造（截至 2026-08-16）

> 本文件记录当前可验证事实、失败路径、证据和剩余工作。工作分支为
> `openrace/task1-rt-partition`，工作区为 `/home/huhu/tgoskits-rt`；
> `/home/huhu/tgoskits` 未修改。

## 0. 目标与验收纪律

目标是让 AxVisor 支持 RT 分区：RTOS vCPU 独占物理核，消除 host 周期 tick
和无关后台活动，使中断排队有界，并用 VM-exit/trace 数据解释虚拟化开销。

验收纪律：

1. 行为修复必须先有能复现旧问题的回归，再修到通过。
2. 实验必须保存命令、配置、原始日志、CSV、统计、运行时长和 sha256。
3. QEMU TCG 数据只用于相同平台下的趋势比较，不声明硬件实时上界。

## 1. 分支与提交基线

分支基于 `openrace/task3-realtime-virq`。接管时已有 11 个本地提交：

| commit | 内容 | 当前判定 |
|---|---|---|
| `818cbc252` | 抢救 day4-6 实验资产 | 完成；实验机 `/tmp/ab-*.log` 仍待提供 |
| `46fa726b9` | per-CPU VM-exit 计数与 `vmexit stat` | 完成 |
| `8862571bd` | vMPIDR 与物理 affinity 解耦 | 完成 |
| `cfa745d02` | RT 双 Guest 配置与分配表 | 完成 |
| `8bb2ff175` | cyclictest/stress-ng 工具链 | 完成 |
| `321acb00d` | 暂存目录忽略规则 | 完成 |
| `54f204b92` | dedicated pCPU 无周期 tick | 完成 |
| `bf5d693cb` | per-VM WFI trap 配置基础 | 已由 capability policy 收紧 |
| `694b1e9bd` | sched-rr/IPI 尝试 | 已回退 |
| `9b45e115d` | 回退 RR/preempt，暂留 IPI | 后续继续回退 |
| `60e5ce5df` | guest FDT CPU 重编号并回退 IPI | 当前调度最终态 |

后续代码修复按 somehal、console、CPU 隔离、WFI、vIRQ、FDT、配置校验、CPU 启动、
诊断和串口控制拆分提交；测量流水线与小型实验数据也已分别提交。当前只保留重复的
hypervisor/Linux/initramfs/Zephyr 构建二进制为未跟踪本地产物，未推送远端。

## 2. 实现核查与修复结果

### 2.1 VM-exit 计数和 vMPIDR

- `vmexit_stats.rs` 使用 cacheline 对齐的 per-CPU Relaxed 原子，区分 timer、
  IRQ、MMIO、WFI、HVC/SMC、sysreg、GIC、SGI 等原因。
- `vmexit stat` 输出累计值和调用间速率。
- guest vMPIDR 使用 vCPU 序号；vGIC 同时保存 guest affinity 和 physical
  affinity，避免 SGI/IROUTER 语义与物理 SPI 路由再次耦合。
- guest FDT CPU `reg` 按虚拟编号重写，Linux vCPU0/1 放在 pCPU2/3 时可 SMP
  启动。

### 2.2 Dedicated pCPU 无 tick

- `dedicated_cpus=` 从 host bootargs 解析为运行时 mask，默认空 mask 不改变
  ArceOS/StarryOS 行为。
- dedicated pCPU 不初始化、不续期 host 周期 deadline；只保留 axtask/VM
  事件驱动 oneshot。
- 正式 RT 拓扑只设置 `dedicated_cpus=1`。旧的 `1,2,3` 会错误关闭 Linux host
  pCPU2/3 的 timer，导致 Linux guest 内 `sleep`/cyclictest 停滞，已修正。

### 2.3 WFI capability 决策

旧文档“只要 dedicated 就清 HCR_EL2.TWI”不成立。当前 world switch 对 CNTV
有硬件 wake path，但 guest CNTP 仍由软件模拟，需要 trapped WFI 来安排 host
timer。因此当前策略是：

- shared vCPU 始终 trap WFI；
- dedicated vCPU 只在所有暴露的 guest timer 都能硬件唤醒时才允许不 trap；
- 当前 CNTV=true、CNTP=false，所以 dedicated Zephyr 仍 trap WFI。

三个单元测试分别固定 dedicated+emulated timer、shared vCPU、全硬件 wake 三种
决策。配置文档不再声称 steady-state 必然 zero-exit。

### 2.4 Linux 测量拓扑与采样完整性

旧脚本把 cyclictest 放 CPU0、隔离 CPU1、stress 又尝试 CPU1，实验口径相反。
当前拓扑为：

| 角色 | Linux guest CPU |
|---|---|
| cyclictest/measurement | CPU1（默认 `RT_CPU=1`） |
| `isolcpus` | CPU1 |
| stress/IRQ housekeeping | CPU0 |

runner 只接受 CPU0/1，并动态计算 `load_cpu=1-rt_cpu`。stress-ng 由 BusyBox
`taskset` 外层启动；cyclictest 启动时先看到全部 online CPU，再由 `-a` 自绑，
规避 musl/libnuma 在稀疏继承 affinity 下误判 CPU 数的问题。

启动参数仍请求 `nohz_full=1`，但当前 guest kernel 明确打印
`Housekeeping: nohz unsupported. Build with CONFIG_NO_HZ_FULL`。因此当前证据只
能声明 affinity/IRQ 分离，不能声明 Linux guest 的 full-dynticks isolation 已生效。

cyclictest 统计现在同时保留 histogram bucket 和 overflow。验收要求：

```text
bucket_samples + overflow_samples = total_samples = RT_LOOPS
```

新 `cyclictest-summary.txt` 保存 min/avg/max、bucket、overflow、total，且进入
sha256 证据。不能再把只有数百个 in-range bucket 的结果误报为完整 5000 样本。
短 smoke 继续用精确 loop 模式；正式矩阵和稳定性改用 cyclictest `-D` duration
模式，因为受压 TCG 下固定 loop 数并不等于固定 guest 时长。duration 验收读取
guest `/proc/uptime` 的 cyclictest 前后值，要求覆盖至少 90% 请求时长；样本数只做
histogram 完整性统计，runner 墙钟只做元数据。

Zephyr sampler 现在支持 UART start gate。runner 先等 Linux 输出
`RT_CYCLICTEST_START`，再切到 Zephyr 控制台发送 `g`，因此 300 个 Zephyr 样本确实
位于 Linux workload 窗口内。VM-exit 取 workload-before、Zephyr-after、Linux-final
三个快照，避免 3 秒 Zephyr 数据被后续长时间 idle 计数淹没。

### 2.5 Guest console 停滞

双 Guest 下 Zephyr 曾卡在 `printk`。根因不是 guest timer，而是 guest UART
read/write 每次都竞争全局 `std::sync::Mutex<ConsoleState>`；console attach、格式化
或物理 UART 输出可让 vCPU 长时间等待。

当前每个 serial backend 使用独立的 bounded `IrqSafeMutex` input/output ring：

- guest UART I/O 不获取全局 console state/output lock，不分配；
- output ring 64 KiB，housekeeping 每次最多 drain 4 KiB；
- 格式化与物理 UART 写仍在 housekeeping path；
- backend generation 替换/停止时 deactivate，迟到 I/O 不串到新实例。

`guest_write_does_not_wait_for_console_control_state` 在旧实现上失败，修复后通过。

### 2.6 vIRQ 有界队列和锁路径

- 每 vCPU 软件中断队列容量 64，overflow 显式返回并产生 trace。
- `pop_if` 每次只弹一个可注入 edge；busy head 保留在队列。
- 注入后端瞬时满时使用队列外 retry slot，避免并发 producer 填满队列后无法
  恢复已弹出的 edge；retry slot 计入 `has_pending`。
- `enqueue_start -> enqueue` 测量 lookup/queue lock，`enqueue -> notify` 测量锁外
  wake。notify、IPI、callback 不在 dispatcher lock 内执行。
- 详细证据见 `results/task1/locking-discipline.md`。

### 2.7 vGIC maintenance

T3.2 不需要新增接线。当前 arm_vgic 已在 LR 外有 pending/active work 时设置
UIE/NPIE/LRENPIE/TDIR；host maintenance PPI 由 FDT 发现并 per-CPU enable。
每次 guest exit 都保存/折叠 ICH state，下一次 guest entry 前 refill LR。

`lr_exhaustion_queues_and_refills_without_repeating_completed_edges` 验证一 LR、两 edge
场景不会丢失或重复。完整说明见 `results/task1/vgic-maintenance.md`。

### 2.8 Zephyr 构建和 native baseline

- `build-zephyr-periodic.sh` 把相对 `OUT_DIR`/`BUILD_DIR` 规范为绝对路径，修复
  CMake 从其他目录解析 overlay 失败。
- native 镜像按 QEMU `virt` 原生基址 `0x40000000` 构建。
- `run-native-zephyr.sh` 固定 QEMU 参数、提取恰好 300 行 CSV、运行统一统计，
  保存 ELF/BIN/manifest/命令/元数据/原始日志和 sha256。

当前 native TCG 结果：

| metric | value |
|---|---:|
| samples | 300 |
| mean jitter | 405.783 us |
| p99 | 599.056 us |
| max | 836.048 us |

证据：`results/task1/native-zephyr/`。这些数字不表示物理硬件的最坏延迟。

## 3. 调度失败路径与当前边界

### sched-rr/preempt

启用 sched-rr/preempt 后，guest 运行期间 EL2 IRQ 进入 ArceOS 抢占检查，world
switch 状态被任务切换破坏，出现 ESR `0x96000005` data abort 循环。FIFO+preempt
同样回归，因此完整抢占接线已回退。

### IPI + dedicated

仅保留 IPI 时常规 smoke/axtest 可过，但与 dedicated pCPU 组合后 secondary core
enable 会在 50% 等待，CORES 无法到 4。最终回退 IPI 后 4/4 稳定。当前调度是
协作式 FIFO；`RT_TASK_PRIORITY=90` 只是意图元数据，因为 FIFO 的
`set_priority` 是 no-op。不能在报告中声称“就绪即优先级抢占”已经完成。

## 4. 已完成验证

- axvm host tests：`286 passed, 0 failed`。
- axvisor axtest：`84 passed, 0 failed`，`AXTEST_SUITE_OK`。
- Python 回归覆盖 Linux affinity、外层 taskset、Zephyr timeout、dedicated mask、
  histogram overflow accounting、Zephyr 相对构建路径、native runner 合同。
- `cargo clippy -p ax-runtime` 基础 feature 与 `irq,multitask,smp` RT feature 组合通过；
  完整 feature 矩阵的 `aic8800-wifi` 检查因外部固件下载连接被拒绝而未完成。
- `cargo check -p ax-runtime --tests`、`cargo fmt --all -- --check` 和 `git diff --check`
  通过；裸机 runtime 的 `cargo test` 链接阶段仍需要平台 linker script 符号，不能在
  host test linker 下直接执行。
- 短矩阵 smoke 四场景全部通过：Zephyr `300/300`，cyclictest `5000/5000`。
- duration 模式早期 10 秒 stress-noiso smoke 完成 `9349` 个完整计数样本；该版
  尚未记录 guest uptime，只用于证明 `-D` 流程能结束。
- 最终 gated 20 秒 stress-noiso smoke 通过：`16,333` 样本，guest uptime 覆盖
  `20.80` 秒；Zephyr start/complete 严格位于 Linux start/complete 之间，三份
  VM-exit 快照和全部归档 sha256 通过。

短矩阵样本分解：

| scenario | bucket | overflow | total |
|---|---:|---:|---:|
| idle | 363 | 4637 | 5000 |
| stress-noiso | 153 | 4847 | 5000 |
| stress-rt | 196 | 4804 | 5000 |

短 smoke 位于 `tmp/rt-partition/validation-results/`，只证明流程和计数完整，不能
代替 30 分钟性能结论。

### 4.1a 本轮长校准与 no-tick 证据

- `stress-dedicated` 20 秒 duration smoke 通过：Zephyr `300/300`，cyclictest
  `15,318`（bucket `15,304` + overflow `14`），guest uptime `38.27 s`；
  `host-periodic-ticks.csv` 中 pCPU1 三个快照均为 `count=0, delta=0`。
- `stress-rt` 60 秒尝试在 guest uptime `49.36 s` 后无进度，watchdog 300 秒后
  拒绝；中间快照 pCPU1 周期 tick 仍为 0，但该运行不是成功稳定性证据。
- 120 秒 idle 校准完成，guest progress `120.15 s`、推荐 scale `2`；
  120 秒 stress-noiso 校准完成，progress `110.73 s`、推荐 scale `2`。
- 120 秒 stress-dedicated 校准曾在 guest uptime `109.83 s` 后停滞，未生成接受
  产物；该记录保留为 `IRQ_ROUTES` 修复前的失败证据。修复后的 dedicated/RT 正式
  duration 运行均已完成，但它们仍使用保守的默认 scale 3，而不是伪造校准条目。
- runner 现在解析 `host-periodic-ticks.csv`；`stress-dedicated` / `stress-rt`
  对 pCPU1 强制 cumulative/delta 均为 0。event-driven timer IRQ/WFI 计数不再
  被误当作 host 周期 tick。

### 4.1 正式矩阵当前状态

- 根因修复后的统一 duration 矩阵四项均已正式通过，证据均位于
  `results/task1/matrix/formal-postfix-2026-08-16/`：
  - `idle`：请求 1800 guest 秒，完成 `1,713,691` 个完整样本，progress 覆盖
    `1792.17 s`，guest/host ratio `1.000001676`，Zephyr `300/300`，全部 sha256
    通过，无 `post-stall/`。
  - `stress-noiso`：请求 1800 guest 秒，完成 `1,746,156` 个完整样本（bucket
    `1,746,142` + overflow `14`），progress 覆盖 `1794.90 s`，guest/host ratio
    `1.000157997`，Zephyr `300/300`，全部 sha256 通过，无 `post-stall/`。
  - `stress-dedicated`：完成 `1,727,468` 个完整样本（bucket `1,727,456` +
    overflow `12`），progress 覆盖 `1794.86 s`，guest/host ratio `0.999497353`，
    Zephyr `300/300`，全部 sha256 通过，无 `post-stall/`；pCPU1 在 before、
    Zephyr-after、Linux-final 三次快照的 host periodic tick 均为 `count=0, delta=0`。
  - `stress-rt`：完成 `1,720,603` 个完整样本（bucket `1,720,591` + overflow
    `12`），progress 覆盖 `1795.09 s`，guest/host ratio `1.000009295`，Zephyr
    `300/300`，全部 sha256 通过，无 `post-stall/`；pCPU1 三次 host periodic tick
    快照同样全部为 `count=0, delta=0`。
- Zephyr 的正式 mean/p99/max jitter 在 `stress-rt` 为
  `614.024/810.224/882.672 us`：相对 `stress-noiso` 分别下降约
  `7.69%/4.46%/4.00%`，相对 `stress-dedicated` 分别下降约
  `13.73%/21.27%/17.29%`。Linux cyclictest avg 从 `stress-noiso` 的 `510 us`
  增至 `stress-rt` 的 `604 us`，因此结论限定为 Zephyr RT 分区路径改善，不声明
  Linux 或全系统延迟同步改善。
- `stress-noiso` 第一次完成 workload 后，runner 在排空约 720 行 `RT_CPUSTAT` 时仍
  使用硬编码的 30 秒 `RT_INIT_DONE` 等待，读到约第 301 个样本即超时并终止 QEMU。
  该失败保存在 `stress-noiso-failed-result-drain-30s/`，日志中已有
  `RT_CYCLICTEST_COMPLETE`，因此不是 OS stall。runner 新增
  `RT_RESULT_DRAIN_TIMEOUT_SEC`（默认 180 秒），纳入完整外层预算和 `meta.txt`；正式
  复跑从 completion 到 `RT_INIT_DONE` 实际约 39.36 秒，证明修复覆盖了真实排空量。
- `idle` 的旧 loop-mode 运行完成 `1,800,000/1,800,000`，但不作为统一正式矩阵：
  stress 场景证明固定 loop 在 TCG 下不能表达固定时长。
- `stress-noiso` 固定 loop 模式分别在 2040 秒、3900 秒超时；guest 仍存活，但未
  完成 1,800,000 loops。该失败促成 duration 模式修正。
- duration-mode `idle` 又分别在默认 TCG scale 1（2100 秒）和 scale 2（3900 秒）
  超时；两次 guest 都未 panic，Zephyr 300/300 已完成，但 Linux 尚未输出
  `RT_CYCLICTEST_COMPLETE`。失败证据保存在
  `failed-idle-duration-scale{1,2}/`。20 秒 smoke 的时间倍率不能外推到 30 分钟，
  runner 默认预算已用先失败回归提升为统一 scale 3，正式复验仍待运行。
- 本轮在 `results/task1/matrix/formal-2026-08-15/idle/` 重新运行 1800 秒 duration
  模式，guest progress 稳定到 `659.70 s` 后停止；300 秒 watchdog 拒绝，仍未出现
  panic 或 `RT_CYCLICTEST_COMPLETE`。后续 1800 秒诊断运行在 `1710.75 s` 后再次
  停止，并通过 QMP 寄存器快照定位到 `somehal::irq::IRQ_ROUTES` 全核自旋死锁；
  根因和修复见下一节。
- 旧 idle 的日志/CSV内部数据仍可检查，但其 sha256 清单曾引用会被重建覆盖的
  `tmp/`/`target/` 输入，当前已有两项漂移。runner 已改为归档 Linux kernel、
  initramfs、Zephyr image/manifest 和 AxVisor binary 后再生成相对路径哈希；旧结果
  不补造二进制，也不标成全哈希通过。

### 4.2 `IRQ_ROUTES` 长时死锁根因与修复

- 失败证据位于 `results/task1/matrix/diagnostic-1800-2026-08-16/idle/post-stall/`。
  QMP 报告虚拟机仍为 `running`，但两次相隔 0.5 秒的寄存器快照中四个 pCPU 都停在
  `ax_task::sync::bridge::spin_acquire`，并争用同一地址 `0xffff847b5860`；该地址由
  `llvm-nm` 解析为 `somehal::irq::IRQ_ROUTES`。
- `1ab948f77` 将原 `SpinNoIrq` 迁移为通用 `SpinLock`。写路径改用了
  `lock_irqsave()`，但 `resolve_irq_route()` 和 `parent_irq_for_leaf()` 仍直接调用
  `.lock()`。迁移前 `.lock()` 会关闭本地 IRQ，迁移后只禁止抢占。
- 普通控制路径持有 `parent_irq_for_leaf()` 的读锁时若被硬 IRQ 打断，中断路径会从
  `ActiveIrq::id()` 再次进入 `resolve_irq_route()` 并获取同一把锁。同一 CPU 无法
  返回被打断的持锁代码，其他 CPU 随后也全部自旋。这解释了故障窗口随机、900 秒
  可通过而 1800 秒可失败的现象。
- 新增 `platforms/somehal/tests/irq_route_locking.rs`，旧实现确定性失败；修复将两个
  读路径统一收口到 `irq_routes()` 的 `lock_irqsave()`。同时修复迁移后测试模块遗留
  的无效 `Mutex<()>` 类型，使 `somehal` 单元测试代码重新可编译。
- 修复后 idle loop-mode 完成 `1,800,000/1,800,000` 样本，guest 进度
  `1832.21 s`，host/guest 比 `0.999845237`，跨过旧 `1710.75 s` 故障点并正常输出
  `RT_CYCLICTEST_COMPLETE`。Zephyr `300/300`，全部归档 sha256 通过，且未生成
  `post-stall/`。证据位于 `results/task1/matrix/idle/`。
- 该运行用于根因修复验证，仍是 loop-mode；其后四场景统一
  `RT_DURATION_SEC=1800` 正式矩阵已经全部通过。

## 5. 剩余工作

### 可在当前环境继续

- T2.2：四场景 `RT_DURATION_SEC=1800` 统一正式矩阵已全部通过。
- T2.3：一小时 `stress-rt` stability 已通过功能验收：`3,347,556` 个完整 Linux
  样本，guest elapsed `3598.96 s`，Zephyr `300/300`，pCPU1 三次 host tick 快照
  全零，全部 sha256 通过，无 `post-stall/`。
- 一小时 Linux avg/P90/P95/P99/P99.9/max 为
  `679/872/950/2061/9212/304760 us`。相对同配置 30 分钟运行，avg 增加
  `12.42%`，P99 增加 `94.43%`，max 增加 `0.55%`；因此只声明功能长稳和 no-tick
  隔离，不声明长尾延迟没有退化。
- T4.1/T4.2：设计文档和总索引已回填正式矩阵、stability 结论和限制。
- 最终回归已完成：Python `38/38`、AxVM `286/286`、AxVisor axtest `84/84`、
  somehal IRQ 锁回归、arm_vgic source hygiene、somehal/ax-runtime check 与 Clippy、
  正式 AArch64 双 Guest 配置构建、`cargo fmt --check`、`git diff --check` 均通过；
  正式矩阵、stability、native、overload、virq-ab 的 sha256 全部通过。
- 最终跑 Python、somehal、axvm、arm_vgic、axtest、fmt、diff-check 和全部 sha256。

### 外部阻塞

- 实验机 `/tmp/ab-*.log`、`/tmp/e1-*.log` 不在本机，无法伪造或复算；待用户
  提供后补入 `results/task1/virq-ab/raw/`。
- 无物理板，因此 T3.5 和硬件 WCET/中断延迟上界不能完成。

## 6. 关键路径

| 内容 | 位置 |
|---|---|
| 工作日志 | `results/task1/WORKLOG.md` |
| 分配表 | `results/task1/allocation-table.md` |
| vGIC maintenance 核实 | `results/task1/vgic-maintenance.md` |
| 锁纪律与死锁分析 | `results/task1/locking-discipline.md` |
| native Zephyr 基线 | `results/task1/native-zephyr/` |
| 短矩阵 smoke | `tmp/rt-partition/validation-results/` |
| 历史 vIRQ 资产 | `results/task1/virq-ab/` |
| 构建/运行/回归脚本 | `scripts/test/rt-partition/` |
