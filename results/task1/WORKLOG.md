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



## T0.4 多核 Linux 客户机配置【配置完成，QEMU 验证待实验阶段】

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

## T0.5 Linux 侧测量流程（cyclictest + stress-ng）【未开始】

## T1.1 RT 核 tick 隔离【未开始】

## T1.2 RT 分区配置档【未开始】

## T2.1 调度抢占【未开始】

## T2.2 三组矩阵实验【未开始】

## T2.3 长时稳定性【未开始】

## T3.1 过载/积压实验【未开始】

## T3.2 vGIC EOI 即时重试核实【未开始】

## T3.3 锁临界区文档化【未开始】

## T3.4 native Zephyr 基线对比【未开始】

## T4.1 正式设计文档【未开始】

## T4.2 results/task1 总索引【未开始】
