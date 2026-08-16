# Task1 WORKLOG（实时 RTOS 化改造工作日志）

> 每个小任务：做什么、遇到的问题、如何解决的、完成标准验证结果、耗时。
> 所有改动/产物以本日志为准追溯；原始日志与 sha256 见各子目录。
> 工作分支：`openrace/task1-rt-partition`（基于 `openrace/task3-realtime-virq` @ 7e77b87e3）。
> 工作区：`/home/huhu/tgoskits-rt`（git worktree，不动 `tgoskits` 主 checkout）。

---

## T0.1 抢救旧分支实验资产【进行中】

### 遇到的问题

1. **ab-*.log / e1-*.log 不在本机**：todo 要求的 `/tmp/ab-A*.log`、`/tmp/ab-B*.log`、
   `/tmp/e1-*.log`、`/tmp/ab-{A,B}-dual-boot.log` 在本机 `/tmp` 和所有仓库 clone 中均不存在
   （`find /home/huhu -name "ab-*" -o -name "e1-*"` 无结果）。这些日志在"实验机"的 `/tmp`
   下，需要从实验机拷贝或用户提供。**阻塞项：待用户提供日志或确认位置。**
2. **tgoskits-realtime 是实际实验 clone**：本机 `/home/huhu/tgoskits-realtime`（当前分支
   `openrace/realtime-virq-ab`）的 `results/day4-6/` 是近期已抢救保存的成果（day5 日志
   原始名即 `/tmp/day5-dual-idle-fixed.log` 等，已改名入仓）；`tmp/` 下有
   `zephyr-periodic` 二进制、`initramfs-custom`、`initramfs-custom-root`、`vmconfigs/`
   （zephyr-soft-virq-smp2.toml、zephyr-soft-virq-suspend-smp2.toml）。
3. **todo 中 T0.1 的 A/B 原始日志（mean 311→301µs、E1 124→0 那批）本机无副本**：README
   先用现有 day4-6 资产写，virq-ab 原始日志待补齐后补充 sha256 与复算。

### 已完成

- [x] 新建分支 `openrace/task1-rt-partition`（基于 task3-realtime-virq @ 7e77b87e3）
- [x] 建立 `results/task1/` 目录骨架（virq-ab/raw、exit-baseline、cyclictest、
      tick-isolation、matrix、stability、overload）
- [x] 本 WORKLOG
- [x] 确认基线分支脚本齐全：`scripts/test/{virq_latency_stats.py,rt_latency_stats.py,
      zephyr-periodic,zephyr-soft-virq,zephyr-soft-virq-suspend}` 与
      `scripts/test/net-dual-guest/` 全套（含 `qemu-aarch64-p2-switch.toml`、
      `build-linux-initramfs.sh`、`qemu-aarch64-p2-stability-1h.toml`）均在。
- [x] 从 `tgoskits-realtime/results/day4-6/` 抢救资产 → `results/task1/virq-ab/raw/`
      （CSV 与日志，含 day5 原始日志改名对 `axvisor-dual-{idle,stress}.log`）
- [x] 对每个抢救文件生成 sha256 → `results/task1/virq-ab/sha256sums`
- [x] 从 git 对象库取回旧分支两份私人文档
      `docs/my/openrace-virq-ab-status.md`、`docs/my/openrace-realtime-progress.md`
      （git 分支 `realtime-virq-ab`，`git show`）→ 作为 T4.1 素材暂存
- [x] 写 `results/task1/virq-ab/README.md`（资产状态表、统计命令、复算结果、
      数据完整性记录）
- [ ] 实验机 `/tmp` 原始日志补拷 + sha256 补录（**等待用户/实验机**）

### 遇到的问题（T0.1）

1. **ab-*.log / e1-*.log 本机不存在**：在实验机 `/tmp`（重启即丢），本机所有 clone
   均无。README 中 311→301µs 复算挂起。已记录在 virq-ab/README.md 数据完整性记录 #2。
2. **day5 README 数字与复算不一致**：旧 README dual-idle mean 253.909µs/p99
   349.872µs vs 复算 257.257µs/524.864µs。判定 CSV 被覆盖，以复算为准。记录 #1。
3. **day6 stress CSV 缺行（294/300）**：共用串口丢行，不用于正式结论。记录 #3。

### 验证

- [x] `python3 scripts/test/virq_latency_stats.py` 可运行（帮助/参数检查）
- [x] `python3 scripts/test/rt_latency_stats.py` 对 `native.csv`、`axvisor-dual-idle.csv`
      复算出数字，已写入 virq-ab/README.md 复算表
- [x] `sha256sum -c sha256sums` 全部通过

---

## T0.2 per-CPU exit-reason 计数器【已完成】

### 实现

1. 新模块 `virtualization/axvm/src/vmexit_stats.rs`：
   - `ExitReason` 12 类：irq / timer / mmio / wfi / hvc-smc / sysreg / gic-if /
     sgi / cpu-up / sys-down / nothing / other
   - per-CPU 计数器槽 `#[repr(align(64))]`（cacheline 对齐防伪共享），
     `MAX_TRACKED_CPUS = 64`，`Relaxed` 原子纯统计
   - API：`note_exit(cpu, reason)`、`vmexit_stats_snapshot()`、
     `vmexit_stats_reset(cpu)`；lib.rs 公开导出
2. 接线 `virtualization/axvm/src/arch/aarch64/mod.rs`：
   - `handle_vcpu_exit_bound` 入口对非 ExternalInterrupt 的 exit 计数，
     分类函数 `classify_vm_exit`
   - `finish_deferred_run_work` 里按 `accept_host_timer_irq(token)` 判定
     Timer vs Irq（保持原有路由语义不变）
3. shell 命令 `os/axvisor/src/shell/command/vmexit.rs`：`vmexit stat` 打印
   每核×原因 累计值 + 自上次调用速率（次/秒），shell 侧存上次快照+时间
   （`LAST_STAT: Mutex<Option<(Instant, Vec<CpuExitCounts>)>>`）

### 遇到的问题

1. **axvm 测试链接失败**：`cargo test -p axvm` 直接跑报
   `__PERCPU_TEMPLATE_ALIGN_END` undefined（someboot 链接符号）。解决：按 CI 口径
   `cargo test -p axvm --features axvm/host-test --no-default-features --lib`。
2. **`self as usize < Self::COUNT` 解析歧义**：`<` 被当成泛型参数，需
   `(self as usize) < Self::COUNT` 加括号。
3. **并行测试污染共享 static**：`counters_are_isolated_per_cpu` 与
   `note_exit_increments_...` 并行跑，共享全局计数器互相覆盖。
   解决：tests 模块内加 `TEST_LOCK: Mutex<()>` 串行化。
4. **非 aarch64 target dead_code**：note_exit/index 只在 aarch64 接线，host
   clippy 报 never used。仿 vcpus.rs 模式加
   `#[cfg_attr(not(target_arch="aarch64"), expect(dead_code, ...))]`。
5. **`this_cpu_id()` trait 不在 scope**：aarch64/mod.rs 需 `use crate::host::HostCpu`。
6. **xtask 命令形态**：`axvisor build qemu --arch` 是错的，正确为
   `tg-xtask axvisor build --arch aarch64 --debug`（qemu 板型在 config 里）。

### 验证

- [x] 5 个 host 单测全过（计数/清零/跨核隔离/越界忽略/名称唯一）
- [x] axvm 全量 `277 passed, 0 failed`（host-test feature，CI 口径）
- [x] `cargo clippy -p axvm --features axvm/host-test --no-default-features --lib` 无新警告
- [x] `cargo fmt -p axvm --check` 通过
- [x] `tg-xtask axvisor build --arch aarch64 --debug` 构建成功
- [ ] QEMU 实跑验证 `vmexit stat` 表格 + 空载 Zephyr ≈100/s 定时器 exit
      （依赖实验资产，放实验阶段一起做）



## T0.3 vMPIDR 与物理放置解耦【已完成】

### 实现

1. `virtualization/axvm/src/arch/aarch64/vm.rs`：`mpidr_el1: placement.phys_cpu_id`
   → `placement.id`（vCPU 序号 0..n 独立编号，placement 只决定跑在哪个 pCPU）。
2. **发现关键耦合点**：`vgic/plan.rs` 的 vCPU affinity 数组同时用于两处语义——
   - **guest 视图**：SGI 匹配（`resolve_sgi_targets` 的 `affinities.contains(&redistributor.affinity())`）
     和 GICD_IROUTER 路由匹配（`state.rs:67` `redistributor.affinity() == route`）
   - **物理路由**：直通 SPI/MSI 的 `set_target_cpu` 目标（physical.rs binding affinity）
   若只改 guest MPIDR 而数组保持物理编号，guest 用虚拟编号发 SGI → 匹配失败，
   副核 IPI 全失效（旧实验 7.4 撞死原因）。
3. **解耦方案（arm_vgic 共享 crate）**：
   - `arm_config.rs`：`VgicV2Config`/`VgicV3Config` 新增 `vcpu_physical_affinities`
     字段 + `with_vcpu_physical_affinities` builder（默认 = guest affinities，向后兼容）
     + validate（长度一致、无重复）
   - `redistributor/mod.rs`：`RedistributorState` 新增 `physical_affinity` 字段 +
     `physical_affinity()` accessor（`affinity()` 语义保持 guest 视图）
   - `controller/mod.rs`：`attach_vcpu` 从 config 取 physical affinity；
     `ControllerConfig` 保存并暴露 `vcpu_physical_affinities()`
   - `controller/physical.rs`：物理 SPI/MSI binding 用 `physical_affinity()`
4. `vgic/plan.rs`：`affinities`（guest）用 vCPU id；新增 `physical_affinities`
   （placement 物理 id）传给两个 config。

### 遇到的问题

1. **SGI/IROUTER 与物理路由共用 affinity 数组**（见上，本次最大发现）。
2. **`AssignedSpiConfig` 要求 identity 映射**（guest INTID == host IRQ），回归测试
   因此用 40/40 而非 1040。
3. **`GicV3VcpuBinding` Drop 即 detach**：`Drop` 里 `state.redistributors.remove()`，
   测试不保存 binding 会导致 redistributor 立即消失（调试定位：两次 attach 后
   map 长度不增长、bind 时 redistributors=[]）。**回归测试必须持有 binding**。
   （为定位此问题加了临时 DBG 打印并已全部清理。）
4. **arm_vgic 是 no_std**，调试不能 eprintln；用 log + 测试内 logger。

### 验证

- [x] arm_vgic 全量 50 测试过（含 5 个新回归：
      `assigned_spi_routes_to_the_physical_affinity_of_its_target_vcpu`、
      `guest_affinities_stay_isolated_from_physical_routing_affinities`、
      `physical_affinities_default_to_guest_affinities`、
      `mismatched_physical_affinity_length_is_rejected`、
      `duplicate_physical_affinity_is_rejected`）
- [x] axvm 277 全过；clippy 无新警告；fmt 通过
- [x] `tg-xtask axvisor build --arch aarch64 --debug` 成功
- [ ] QEMU 实跑：Zephyr/Linux SMP2 在 vCPU0/1→pCPU2/3 拓扑完整启动
      （依赖实验资产，放实验阶段）



## T0.4 多核 Linux 客户机配置【已完成并经正式矩阵验证】

### 实现

1. `scripts/test/rt-partition/qemu-aarch64-rt.toml`：`-smp 4`、串口/QMP
   UNIX socket、`success_regex = ["PERIODIC_LATENCY_COMPLETE"]`
2. `scripts/test/rt-partition/vm-aarch64-rt-linux.toml`：Linux `cpu_num = 2`、
   `phys_cpu_ids = [2, 3]`；cmdline 注入
   `isolcpus=1 nohz_full=1 irqaffinity=0`（通过 `[kernel] cmdline`，
   aarch64 FDT `patch_chosen` 覆盖 bootargs，代码位置
   `boot/fdt/core/create.rs:354`）
3. `scripts/test/rt-partition/vm-aarch64-rt-zephyr.toml`：Zephyr `cpu_num = 1`、
   `phys_cpu_ids = [1]`（独占 pCPU1）
4. `results/task1/allocation-table.md`：pCPU/内存/设备/中断分配表
   （T4.1 素材）

### 遇到的问题

1. **guest bootargs 注入方式**：qemu toml 的 `-append` 不作用于 guest 内核
   （axvisor 裸机场景）。正确路径是 vm toml `[kernel] cmdline` → FDT
   `patch_chosen`。已用 xtask 加载验证字段合法。
2. **kernel_path 占位**：`${workspace}/tmp/rt-partition/` 下镜像需实验阶段
   从 `tgoskits-realtime/tmp/`（linux-qemu、zephyr-task2.bin、initramfs）
   准备。

### 验证

- [x] 三个 toml 语法解析 OK；`tg-xtask axvisor build --vmconfigs ...` 正确
      加载（报"镜像不存在"而非解析错误 = 字段全部合法）
- [x] 分配表完成（allocation-table.md）
- [ ] QEMU 实跑：双 Guest 稳定 ≥10 分钟；`/proc/cpuinfo` 2 处理器；
      `SMP: ... CPU1` 日志（依赖实验资产）



## T0.5 Linux 侧测量流程（cyclictest + stress-ng）【已完成并经正式矩阵验证】

### 实现

1. `scripts/test/rt-partition/build-rt-tools.sh`：一键交叉编译 cyclictest
   （rt-tests）+ stress-ng（aarch64 musl 静态）+ 打包 initramfs
2. `scripts/test/rt-partition/rt-linux-init.sh`：guest 内测量 init——解析
   `rt_*` cmdline、taskset 绑测量核、cyclictest
   `-m -p 90 -i 1000 -l 1800000 -h 400 -q`、stress-ng 场景开关、top -b 采样
3. `scripts/test/rt-partition/cyclictest-hist-to-csv.py`：解析
   `# Histogram Bucket Latencies (us)` → CSV
4. `scripts/test/rt-partition/run-cyclictest.sh`：一条命令跑完
   双 Guest 实验（QEMU 串口 socket + serial_console.py 驱动），产出
   `results/task1/cyclictest/<scenario>/{run.log,cyclictest.csv,top.csv,
   vmexit-stat.txt,meta.txt,sha256sums}`
5. 产物：`tmp/rt-partition/{linux-qemu,zephyr-rt.bin,
   rt-linux-initramfs.cpio.gz}` 已暂存（zephyr 用 zephyr-task2.bin）

### 遇到的问题

1. **rt-tests 硬依赖 libnuma**：新版（2.10）cyclictest 无条件链 `-lnuma`。
   解决：交叉编译 numactl 2.0.18（release tarball，仓库源码缺 autoreconf 工具）
   得到 `libnuma.a`。
2. **旧版 rt-tests 不可用**：v1.8 用 glibc 私有 `struct sigevent::_sigev_un`，
   musl 无此字段。
3. **新版 cyclictest 的 glibc 宏泄漏**：`cyclictest.c:59`
   `#define sigev_notify_thread_id _sigev_un._tid` 无条件定义，与 musl 自带
   宏冲突。本地 patch 为 `#ifdef __GLIBC__` 包裹（记录在 WORKLOG；
   上游未修，实验材料里注明）。
4. **musl 需要 `-D_GNU_SOURCE`** 才有 cpu_set_t/sched_*。
5. **CPPFLAGS 覆盖 Makefile 默认值**：必须显式带 `-Isrc/include`。

### 验证

- [x] `build-rt-tools.sh` 完整跑通，initramfs 含 cyclictest/stress-ng/init
      （sha256=79bb5a44...）
- [x] `qemu-aarch64` 直接执行两个静态二进制成功（cyclictest V 2.10、
      stress-ng 0.21.04）
- [x] 脚本 bash -n / py_compile 语法全过
- [ ] QEMU 实跑一条命令产出全套证据（依赖实验阶段）



## T1.1 RT 核 tick 隔离【已完成】（核心改造）

### 实现

1. **axruntime**（`os/arceos/modules/axruntime/src/lib.rs`）：
   - `DEDICATED_CPU_MASK` + `set_dedicated_cpus(mask)` / `dedicated_cpu_mask()`（opt-in，
     默认空 mask 行为完全不变——StarryOS 共享无影响）
   - `current_cpu_is_dedicated()`：mask 位判断（`ax_hal::percpu::this_cpu_id()`）
   - `advance_periodic_timer`：dedicated 核直接返回 false，**不续期周期 deadline**
   - `program_next_timer`：dedicated 核只走事件驱动——合并 axtask/VM 事件
     deadline（axvm timer wheel），无事件则不编程定时器（无 tick 中断）
   - `init_timer`：dedicated 核不写初始周期 deadline
2. **axvm**：`arch/aarch64/capabilities.rs` 加 `host_bootargs()`（读 host FDT
   chosen/bootargs，新增 `fdt-parser` 依赖），re-export 链补齐
3. **axvisor**：
   - `config.rs`：`dedicated_cpus_from_bootargs(bootargs) -> usize`（解析
     `dedicated_cpus=1,3`）
   - `main.rs`：aarch64 下读 host bootargs → `set_dedicated_cpus(mask)`（opt-in）
   - 用法：qemu `-append` 加 `dedicated_cpus=1`（如 rt qemu toml）

### 周期活动清单核查（dedicated 核上逐项确认）

| 周期活动 | 判定 | 说明 |
|---|---|---|
| `advance_periodic_timer` 续期 | 已消除 | dedicated 核跳过 |
| `scheduler_clock_tick` | 随动 | 仅 timer IRQ 时跑；无周期定时器则不跑 |
| `program_next_timer` 周期重设 | 已消除 | dedicated 只按事件 deadline |
| axlog 定时刷新 | 无 | axlog 无定时器驱动 |
| IPI 广播 | 按需 | 无周期广播 |
| axtask timer wheel | 保留 | 事件驱动 oneshot，VM 唤醒/注入定时器正常 |
| vCPU 设备轮询（poll_primary_vcpu_devices） | 保留（待观察） | vCPU run loop 的 yield 轮询，非中断源，文档记录 |

### 遇到的问题

1. **axvisor 找不到 axruntime**：axvisor 未直接依赖 axruntime；通过
   `ax_std::os::arceos::modules::ax_runtime`（ax_api re-export）调用。
2. **host_bootargs 的 fdt API 版本差异**：axvm 用 fdt-edit，ax_hal 用 fdt-parser
   0.4（`find_nodes("/chosen")` + `Chosen::bootargs()`），axvm 需新增
   `fdt-parser = "0.4"` 依赖。
3. **多架构编译**：`host_bootargs` 仅 aarch64 有，axvisor main 调用需
   `#[cfg(target_arch = "aarch64")]`。

### 验证

- [x] axruntime host-test：5 测试过（3 个新：mask 选择/空 mask 保旧行为/越界防护）
- [x] clippy ax-runtime 无新警告；fmt 通过
- [x] axvm 277 全过；axvisor aarch64 构建成功
- [x] axvisor config 单测（`dedicated_cpus_from_bootargs` 5 个）已写，跑法走
      ktest（QEMU，实验阶段）
- [ ] QEMU 实跑：`vmexit stat` 定时器 exit ≈100/s → ≈0（T0.2 基线对比，
      实验阶段）



## T1.2 RT 分区配置档【已完成；WFI 按能力保守处理】

### 实现

1. **per-VM WFI trap 开关与 timer capability policy**：
   - `arm_vcpu`：`ArmVcpuSetupConfig` 加 `trap_wfi: bool`（默认 true，行为不变）
     + `with_trap_wfi()`；`init_vm_context` 按它设置 `HCR_EL2::TWI`。
   - `axvm/arch/aarch64/wfi.rs`：shared vCPU 始终 trap；dedicated vCPU 也只有在
     所有暴露 guest timer 都有硬件 wake path 时才允许清 TWI。
   - 当前 CNTV 由硬件 world switch 恢复，CNTP 仍软件模拟，因此 dedicated
     Zephyr 仍 trap WFI。旧的“dedicated 必然不 trap”结论已撤销。
2. **`scripts/test/rt-partition/rt-partition-zephyr.toml`**：一次配齐
   - `guest_type = "passthrough"`（直通 GIC + 虚拟定时器）
   - `phys_cpu_ids = [1]`（独占 pCPU1）
   - dedicated tick：qemu `-append "dedicated_cpus=1"`（已更新
     `qemu-aarch64-rt.toml`）
   - WFI trap：由 dedicated placement 与 timer wake capability 共同判定
3. Linux guest 保持 virtualized；guest CPU1 测量，guest CPU0 承担 stress/IRQ
   housekeeping。host 只有 pCPU1 进入 dedicated no-tick mask。

### 遇到的问题

1. **`|=` 不适用于 tock_registers FieldValue**：HCR_EL2 组合用 `hcr_el2 = hcr_el2 + HCR_EL2::TWI::SET`。
2. **不能只按 placement 清 TWI**：CNTP 软件模拟需要在 trapped WFI 时安排 host
   timer。否则 dedicated vCPU 可能永远收不到 CNTP wake。通过 capability model
   收紧策略，并用三种组合的回归固定行为。
3. **SetupConfig 是 VM 级**（closure 无 per-vCPU 参数）：RT 分区场景
   （guest 所有核独占）VM 级判定足够；混合拓扑仍需后续细化。

### 验证

- [x] WFI capability 三个单测过；axvm host tests 282 过；fmt 通过
- [x] axvisor aarch64 构建成功；新配置 toml 解析 OK
- [x] QEMU 短矩阵：RT 分区 Zephyr 300/300；vmexit 前后快照已自动归档
- [ ] 正式长实验后分析各 exit reason；当前不声明所有 WFI/timer exit 都为零



## T2.1 调度抢占【尝试后回退；当前为协作式 FIFO】

### 尝试与最终状态

1. `sched-rr + preempt + ipi` 在 guest world switch 中触发 EL2 data abort
   (`ESR=0x96000005`)；改成 FIFO+preempt 仍复现，因此全部回退。
2. 仅启用 IPI 时常规 smoke/axtest 可过，但与 dedicated pCPU 组合后 secondary
   core enable 在 50% 卡住，CORES 无法到 4；IPI 也最终回退。
3. **关键任务优先级意图**：`RT_TASK_PRIORITY = 90` 设置到：
   - vCPU run 任务（`build_vcpu_task`）
   - axvm-timer worker（timer.rs:325）
   - vIRQ 注入器（`spawn_periodic_virq_injector`）
   - 注：当前 FIFO 的 `set_priority` 是 no-op，所以这些值只是意图元数据，
     不能作为“就绪即抢占”完成证据。

### 遇到的问题

1. **world switch 与 IRQ 中抢占不兼容**：不是简单 feature 接线问题，需要明确
   IRQ 栈、vCPU context 和 scheduler handoff 的所有权后才能重做。
2. **IPI 与 dedicated startup 存在 race**：当前以回退 IPI 保证 4/4 启动；根因
   尚未完整修复，不能在本任务中声称跨核高优先级抢占成立。
3. **跨核 kick 代码存在不等于端到端正确**：此前只做静态核查，未覆盖
   dedicated secondary startup 交互，真实 QEMU 才暴露组合回归。

### 验证

- [x] 回退后的 release QEMU 双 Guest 4/4 稳定启动
- [x] axvm host tests 与 axvisor axtest 在当前最终态通过
- [ ] 完整 RT 抢占调度器是后续架构工作，不纳入本分支完成声明

## T2.2 四场景矩阵实验【正式完成】

三场景均完成 5000/5000 cyclictest 样本与 Zephyr 300/300。短结果只验证流程、
affinity 和 overflow accounting，位于 `tmp/rt-partition/validation-results/`。

第一次正式 idle loop-mode 完成 1,800,000 样本；stress-noiso 在 2040 秒超时。
把 stress 场景的 TCG runtime budget 放大为 2 后，第二次仍在 3900 秒超时，guest
存活但 loop 未完成。结论是受压 TCG 中“1 ms interval × loop 数”等于固定时长的
假设不成立。

正式实验现改用 `RT_DURATION_SEC` 驱动 cyclictest `-D`，loop 模式只保留给精确
计数 smoke。最初按 `total_samples * interval_us` 估算 duration 仍不成立：20 秒
stress run 实际运行约 22.7 秒，但严重超时只留下 15,583 个样本。最终验收在 guest
内记录 cyclictest 前后的 `/proc/uptime`，以该单调时钟差验证请求时长；样本数仅用于
bucket+overflow 完整性。

原编排还让 Zephyr 300 样本在 Linux boot 阶段提前结束，没有与 cyclictest/stress
重叠。Zephyr sampler 新增 UART start gate；runner 等 Linux workload start 后才发送
`g`。最终 20 秒 gated smoke 中，Linux start → Zephyr start → Zephyr complete →
Linux complete 顺序通过，guest uptime 20.80 秒，16,333 个完整样本，全部 sha256
通过。VM-exit 现在取 workload-before、Zephyr-after、Linux-final 三个快照。

证据归档也修正为复制 Linux kernel、initramfs、Zephyr image/manifest 和实际构建的
AxVisor binary 到场景目录，再生成相对路径 sha256。旧 idle 清单引用 mutable
`tmp/`/`target/` 路径，当前有两项漂移，故保留为历史 loop-mode 结果但不声明全哈希
通过。状态和失败记录见 `results/task1/matrix/README.md`。

后续正式 duration idle 进一步暴露了运行预算问题：scale 1 在 2100 秒超时，scale 2
在 3900 秒仍超时；两次都没有 guest panic，Zephyr 300/300 已完成，Linux 只是尚未
累计满请求的 1800 guest 秒。两次失败分别归档到
`failed-idle-duration-scale1/` 和 `failed-idle-duration-scale2/`。先把回归从要求
scale 2 提升为要求三个场景统一 scale 3，确认旧实现失败，再修改 runner 并跑到
Python 16/16 通过。正式矩阵仍未完成，不能将 scale 3 写成已验证结论。

### 2026-08-16 根因修复后的正式矩阵

1. `formal-postfix-2026-08-16/idle/` 已完成 1800 秒 duration：`1,713,691` 个完整
   cyclictest 样本，progress `1792.17 s`，guest/host ratio `1.000001676`，Zephyr
   `300/300`，全部归档 sha256 通过，无 watchdog `post-stall/`。
2. 第一次 `stress-noiso` 已输出 `RT_CYCLICTEST_COMPLETE`，但约 720 行运行末尾
   `RT_CPUSTAT` 需要继续从串口排空；runner 硬编码的 30 秒 `RT_INIT_DONE` 等待只读到
   约第 301 个样本便超时并终止 QEMU。失败证据保存在
   `formal-postfix-2026-08-16/stress-noiso-failed-result-drain-30s/`，定性为 runner
   结果收集超时，不是 guest 或 AxVisor stall。
3. `run-cyclictest.sh` 新增 `RT_RESULT_DRAIN_TIMEOUT_SEC`，默认 180 秒，并纳入数字/
   正值校验、minimum outer timeout 和 `meta.txt`。`test_rt_build_scripts.py` 固定该
   合同并禁止恢复硬编码 `expect 30 RT_INIT_DONE`。
4. 修复后 `formal-postfix-2026-08-16/stress-noiso/` 正式通过：bucket
   `1,746,142` + overflow `14` = total `1,746,156`；progress `1794.90 s`，
   guest/host ratio `1.000157997`；Zephyr `300/300`；completion 后约 39.36 秒收到
   `RT_INIT_DONE`；全部 sha256 通过，无 `post-stall/`。
5. `formal-postfix-2026-08-16/stress-dedicated/` 正式通过：bucket `1,727,456` +
   overflow `12` = total `1,727,468`；guest progress `1794.86 s`，guest/host ratio
   `0.999497353`；Zephyr `300/300`；全部 sha256 通过，无 `post-stall/`。pCPU1 在
   before、Zephyr-after、Linux-final 三次 host periodic tick 快照中均为
   `count=0, delta=0`，满足 dedicated no-tick 强制策略。
6. `formal-postfix-2026-08-16/stress-rt/` 正式通过：bucket `1,720,591` + overflow
   `12` = total `1,720,603`；guest progress `1795.09 s`，guest/host ratio
   `1.000009295`；Zephyr `300/300`；全部 sha256 通过，无 `post-stall/`。pCPU1 三次
   host periodic tick 快照全部为 `count=0, delta=0`。
7. Zephyr `stress-rt` mean/p99/max jitter 为 `614.024/810.224/882.672 us`，相对
   `stress-noiso` 改善约 `7.69%/4.46%/4.00%`，相对 `stress-dedicated` 改善约
   `13.73%/21.27%/17.29%`。Linux cyclictest avg 则从 `510 us` 增至 `604 us`，
   所以只声明 Zephyr RT 分区路径的相对改善。

## T2.3 长时稳定性【一小时 stress-rt 已完成】

- `results/task1/stability/stress-rt/` 完成 `RT_DURATION_SEC=3600`：Linux
  `3,347,556` 个完整样本，guest elapsed `3598.96 s`，guest/host ratio
  `1.000018463`；Zephyr `300/300`；全部 sha256 通过，无 watchdog `post-stall/`。
- pCPU1 在 before、Zephyr-after、Linux-final 三次 host periodic tick 快照中均为
  `count=0, delta=0`。
- Linux avg/P90/P95/P99/P99.9/max 为 `679/872/950/2061/9212/304760 us`。
  相比 30 分钟 `stress-rt`，avg/P90/P95/P99/P99.9/max 分别变化
  `+12.42%/+6.21%/+6.26%/+94.43%/+5.95%/+0.55%`。功能稳定性通过，但 P99
  明显变差，不能声明长时尾延迟稳定改善。
- Zephyr 仍只在 workload 起始窗口采 300 点，不能比较一小时首尾窗口；该限制记录
  在 `results/task1/stability/README.md`，不补造时间序列结论。

## T3.1 过载/积压实验【队列级 A/B 已完成】

从 Git `f298ee57b^` 恢复旧无界 `Vec::push` 源码，与当前 capacity-64 源码做同一
到达/服务序列的确定性 replay。50us 到达、1000us 服务、100ms overload 下：

- 旧无界：接收 2000、overflow 0、最大深度 1901、max latency 1900.05ms；
- 当前有界：接收 163、显式 overflow 1837、最大深度 64、max latency 64ms。

证据在 `results/task1/overload/`，含源码快照、events/summary CSV、对比图和 sha256。
该结果证明 queue bound/overflow 语义，不冒充 QEMU 端到端 WCET。

## T3.2 vGIC EOI 即时重试核实【已完成】

arm_vgic 已通过 UIE/NPIE/LRENPIE/TDIR + maintenance PPI + save/refill/load 覆盖
LR 耗尽后的补注入。回归验证 completed edge 不重复，说明见
`results/task1/vgic-maintenance.md`。

## T3.3 锁临界区文档化【已完成】

新增 `enqueue_start` trace，拆分 `enqueue_start->enqueue` 锁路径与
`enqueue->notify` 锁外唤醒；记录 dispatcher、wait queue、machine lock 和 guest
console 的锁顺序与死锁修复，见 `results/task1/locking-discipline.md`。

## T3.4 native Zephyr 基线对比【native 侧已完成】

`run-native-zephyr.sh` 已归档 300/300 样本、原始日志、CSV、统计、镜像、manifest、
QEMU 命令和 sha256。当前 mean/p99/max 为 405.783/599.056/836.048 us；待正式
RT partition 30 分钟数据完成后做同平台差异分析。

## 2026-08-15 实现-日志一致性复核

### Guest console stall

1. 复现表现：Zephyr 在大量串口输出时停在 `printk`，并非 periodic sampler 或
   timer 本身停止。
2. 根因：guest serial backend 的 read/write 竞争全局 `ConsoleState` mutex，vCPU
   会被 console attach、格式化和物理 UART 路径阻塞。
3. 回归：`guest_write_does_not_wait_for_console_control_state` 在旧实现超时/失败。
4. 修复：每 backend 独立 bounded endpoint ring；guest I/O 不获取 global state/
   output lock，不分配；housekeeping 分批 drain、格式化并输出。
5. 验证：相关回归通过；最终 axvisor axtest 84/84 通过。

### Host tick evidence and calibration

1. `vmexit stat` 新增独立的 host periodic scheduler tick 累计值；runner 提取
   `host-periodic-ticks.csv`，dedicated 场景强制 pCPU1 cumulative/delta 为 0。
2. 新增 `host-periodic-ticks-to-csv.py` 及合成日志回归，避免把 guest event-driven
   timer IRQ/WFI exit 误报成 host 周期 tick。
3. 新增 120 秒 per-scenario calibration 工具和 runner。idle/noiso 校准均推荐
   scale 2；dedicated 在 109.83 guest 秒后停滞，stress-rt 在 49.36 guest 秒后停滞，
   两者保留失败证据，不伪造 calibration file 条目。
4. Zephyr UART gate 改为 `send-until`，每 0.5 秒重发 `g`，最长 60 秒；修复
   dedicated TCG 启动时 READY 已在历史缓冲、单次输入丢失或 guest 响应延迟导致的
   假失败。serial driver 有独立重试回归。

### Linux topology and evidence accounting

1. 修正 cyclictest CPU、isolated CPU 和 stress CPU 的反向配置：measurement 默认
   guest CPU1，stress/IRQ 默认 guest CPU0。
2. stress-ng 通过外层 BusyBox taskset 启动，避免 isolated CPU 被继承 affinity
   预先过滤；cyclictest 先以全 online mask 启动，再由 `-a` 自绑。
3. host `dedicated_cpus` 从错误的 `1,2,3` 收窄为 `1`，避免关闭承载 Linux 的
   pCPU2/3 timer。
4. cyclictest 的 overflow 加入总样本，验收固定为 bucket+overflow=RT_LOOPS。
5. Zephyr completion timeout 从 60 秒提高到 180 秒，覆盖双 Guest TCG 启动时间。
6. 三个短场景均完成 cyclictest 5000/5000 和 Zephyr 300/300。
7. guest kernel 缺少 `CONFIG_NO_HZ_FULL`，日志明确报告 nohz unsupported；当前只
   声明 CPU affinity/IRQ housekeeping 分离，不声明 full-dynticks 已生效。
8. 固定 loops 在 stressed TCG 下两次超时；正式矩阵改为 duration mode，并增加
   guest 样本覆盖时长回归。
9. 场景 sha256 不再引用可变的 `tmp/`/`target/` 输入，改为归档后校验。
10. 新 smoke 的启动日志发现 arm_vgic 仍残留两条 `DBG attach/bind` warn，与早期
    “临时调试打印已清理”的记录冲突。先新增 `source_hygiene` 失败回归，再删除两条
    日志；回归现已通过。
11. Zephyr 原先在 Linux workload 前完成，矩阵不满足“同时运行”。新增 UART gate
    和顺序验收，正式样本只在 Linux workload 窗口内启动。

### Regressions added

- `test_rt_linux_affinity.py`：measurement/load 拓扑、taskset、timeout、host mask。
- `test_cyclictest_hist_to_csv.py`：bucket/overflow/total 完整计数。
- `test_rt_build_scripts.py`：相对 Zephyr build 路径、native runner 和正式矩阵输入
  归档合同。
- `enqueue_start_has_a_stable_trace_name`：T3.3 trace 分段名称。
- guest console control-state lock regression。
- `arm_vgic/tests/source_hygiene.rs`：禁止 controller 源码残留 `DBG` 临时日志。
- `test_host_periodic_ticks.py`、`test_runtime_calibration.py`：tick 证据和倍率公式。
- `test_serial_console.py`：门控字节重试直到 START 标记。

### 2026-08-15 本轮验证收尾

- `ax-runtime` 的 periodic tick 统计辅助函数补上 `irq`/`multitask`/test 条件编译，
  修复无 feature clippy 构建中的 dead-code；基础 clippy 与 `irq,multitask,smp` 组合均通过。
- AxVM host tests 当前为 `284/284`；Python RT-partition 回归为 `33/33`。
- 完整 ax-runtime clippy feature 矩阵仍有外部环境失败：`aic8800-wifi` build script
  需要从 GitHub 下载固件，当前连接被拒绝；该失败不是本轮源代码 lint。
- `cargo test -p ax-runtime` 的 test binary 链接缺少裸机 linker script 符号
  (`STACK_SIZE`、`PAGE_SIZE`、percpu template)，改用 `cargo check --tests` 验证测试代码。

## 2026-08-16 `IRQ_ROUTES` 长时死锁定位与修复

1. runner watchdog 新增 QMP 和串口恢复取证。1800 秒 idle 诊断运行在 guest uptime
   `1710.75 s` 后停止；QMP `query-status` 仍为 `running`，Axvisor shell 和 guest
   console 均无响应。
2. 两次寄存器快照中四个物理 CPU 都停在
   `ax_task::sync::bridge::spin_acquire`，锁地址均为 `0xffff847b5860`。符号表将该
   地址解析为 `somehal::irq::IRQ_ROUTES`。原 timer、console 和 QEMU freeze 假设
   因此被排除。
3. Git 考古定位到 `1ab948f77` 的同步原语迁移：原 `SpinNoIrq.lock()` 会关闭本地
   IRQ；迁移后的通用 `SpinLock.lock()` 只禁止抢占。写路径已改为
   `lock_irqsave()`，但 `resolve_irq_route()` 和 `parent_irq_for_leaf()` 两个读路径
   漏改。
4. 死锁链为：普通上下文持有 `parent_irq_for_leaf()` 读锁 -> 本地硬 IRQ 打断 ->
   `ActiveIrq::id()` 调用 `resolve_irq_route()` -> 同 CPU 递归自旋。其他 CPU 随后
   争用同一锁，形成全系统停顿。
5. 先新增 `platforms/somehal/tests/irq_route_locking.rs`；旧实现稳定失败。随后将所有
   `IRQ_ROUTES` 读访问统一改为 IRQ-save helper，并修复 `somehal` 测试模块迁移后
   遗留的无效 `Mutex<()>` 类型。
6. 修复后 AArch64 Axvisor 构建通过；`somehal` 目标回归和 Clippy 通过。完整
   `cargo test -p somehal` 已编译过测试代码，但 host 链接仍被仓库既有裸机符号
   `STACK_SIZE/PAGE_SIZE/__PERCPU_*` 阻断。
7. 长时 idle loop-mode 验证完成 `1,800,000/1,800,000` 样本，guest progress
   `1832.21 s`，host/guest ratio `0.999845237`，正常输出
   `RT_CYCLICTEST_COMPLETE` 并关机。Zephyr `300/300`，归档 sha256 全部通过，未
   触发 watchdog。成功证据在 `results/task1/matrix/idle/`；失败取证保留在
   `results/task1/matrix/diagnostic-1800-2026-08-16/idle/post-stall/`。
8. 本次结果闭环了长时 stall 根因，但属于 loop-mode 修复验证。随后四场景
   duration-mode 正式矩阵和一小时 `stress-rt` stability 均已通过功能验收。

## 2026-08-16 最终验证收尾

- Python 合同测试 `38/38` 通过。
- AxVM host tests `286/286` 通过。
- AxVisor AArch64 axtest `84/84` 通过，输出 `AXTEST_SUITE_OK`。
- somehal `irq_route_locking`、arm_vgic `source_hygiene` 回归通过；
  `cargo check -p somehal --tests` 与 `cargo clippy -p somehal --tests -- -D warnings`
  通过。
- `cargo check -p ax-runtime --tests`，基础与 `irq,multitask,smp` 两组 AxRuntime
  Clippy `-D warnings` 通过。
- 正式 stress-rt 双 Guest 配置的 AArch64 AxVisor release 构建通过。
- `cargo fmt --all -- --check`、`git diff --check` 通过。
- 四场景正式矩阵、一小时 stability、native Zephyr、overload 和 virq-ab 的
  sha256 清单全部通过。

## T4.1 正式设计文档【已完成】

见 `book/design/task1-realtime-design.md`。

## T4.2 results/task1 总索引【已完成】

见 `results/task1/README.md`。
