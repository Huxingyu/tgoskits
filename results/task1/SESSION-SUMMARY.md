# Task1 Session 总结：实时 RTOS 化改造（2026-08-14 单会话全记录）

> 本文件是单个会话（2026-08-14）从零到当前的**完整工作档案**：成功路径、
> 失败路径、方法、探索过程、证据位置，以及剩余 todo。工作分支
> `openrace/task1-rt-partition`（基于 `openrace/task3-realtime-virq` @ 7e77b87e3），
> 工作区 `/home/huhu/tgoskits-rt`（git worktree，主 checkout `tgoskits` 未动）。

---

## 0. 目标与铁律（来自 todo.md）

把 AxVisor 改造为支持 RT 分区：RTOS vCPU 独占物理核，做到**无 tick、无无关
中断、无后台任务、就绪即抢占、中断注入有界**，用 exit 计数解释虚拟化税。
铁律：① 每项改造前先采同口径基线；② 所有产物进 `results/task1/` 带 sha256。
预期得分 27-30 分（原 8-9 分）。

---

## 1. 已提交的 11 个 commit（全部本地，未合并 dev）

| commit | 内容 | 状态 |
|---|---|---|
| `818cbc252` | T0.1 抢救 day4-6 实验资产（sha256 归档） | ✅ |
| `46fa726b9` | T0.2 per-CPU exit 计数器 + `vmexit stat` 命令 | ✅ |
| `8862571bd` | T0.3 vMPIDR 解耦 + vGIC guest/physical affinity 分离 | ✅ |
| `cfa745d02` | T0.4 RT 双 Guest 配置 + 分配表 | ✅ |
| `8bb2ff175` | T0.5 cyclictest/stress-ng 工具链 + 测量脚本 | ✅ |
| `321acb00d` | .gitignore 暂存目录 | ✅ |
| `54f204b92` | T1.1 dedicated 核无 tick（axruntime opt-in） | ✅ |
| `bf5d693cb` | T1.2 per-VM WFI trap 开关（RT 分区档） | ✅ |
| `694b1e9bd` | T2.1 尝试 sched-rr/ipi + RT 任务优先级 | ⚠️ 后续回退 |
| `9b45e115d` | 回退 RR/preempt（world-switch 回归），保留 ipi | ⚠️ 后续再回退 |
| `60e5ce5df` | guest FDT cpu 节点重编号 + 回退 ipi（dedicated 卡死） | ✅ 最终态 |

---

## 2. 成功路径（每个任务的实现方法）

### T0.1 资产抢救（✅）
- **方法**：从实验 clone `tgoskits-realtime`（分支 realtime-virq-ab）拷贝
  `results/day4-6/`（CSV+日志），sha256 归档到 `results/task1/virq-ab/raw/`；
  `git show` 取回 `docs/my/` 两份私人文档。
- **问题**：`/tmp/ab-*.log`（A/B 原始日志）本机不存在——在实验机，**待用户提供**；
  day5 README 数字与复算不一致（判定 CSV 被覆盖，以复算为准）。

### T0.2 exit 计数器 + vmexit stat（✅）
- **方法**：新模块 `vmexit_stats.rs`（`#[repr(align(64))]` per-CPU 槽防伪共享，
  12 类 ExitReason，Relaxed 原子）；接线 `handle_vcpu_exit_bound` 入口 +
  `finish_deferred_run_work`（ExternalInterrupt 按 `accept_host_timer_irq` 分
  Timer/Irq）；shell 命令 `vmexit stat`（累计+速率）。
- **问题**：axvm 测试需 `--features axvm/host-test --no-default-features --lib`
  （CI 口径）；并行测试污染共享 static（加 TEST_LOCK）；`<` 泛型歧义。

### T0.3 vMPIDR 解耦（✅ 代码 + ✅ QEMU 验证）
- **方法**：`vm.rs` mpidr 改用 `placement.id`；**关键发现**：vGIC 的 affinity 数组
  双重语义（SGI/IROUTER 匹配用 guest 视图，物理 SPI 路由用物理视图）——在
  arm_vgic 增加 `vcpu_physical_affinities`（config + RedistributorState）分离两语义。
- **QEMU 验证**（会话后期）：guest FDT cpu 节点 reg 保留物理 id 与 vCPU MPIDR
  不匹配 → 补 `renumber_guest_cpu_nodes`（create.rs）把保留 cpu 节点 reg 重写为
  vCPU 序号 → **`[2,3]` 拓扑 Linux SMP 2 核完整启动**（T0.3 完成标准达成）。

### T0.4 多核 Linux 配置（✅）
- **方法**：`scripts/test/rt-partition/` 三件套（qemu-aarch64-rt.toml `-smp 4`、
  Linux 2 vCPU `[2,3]` + cmdline、Zephyr 1 vCPU `[1]`）+ 分配表。
- **坑**：passthrough/disabled 必须 `{ path = "..." }` 结构（旧字符串格式报错）；
  `kernel.cmdline` 是 guest bootargs 正确注入通道（aarch64 patch_chosen）。

### T0.5 测量流程（✅）
- **方法**：交叉编译 cyclictest（rt-tests v2.10 + numactl 2.0.18 libnuma 静态）、
  stress-ng（STATIC=1）→ 塞 initramfs；`run-cyclictest.sh` 一条命令跑完并产出
  证据；`cyclictest-hist-to-csv.py` 直方图转 CSV。
- **坑**：rt-tests 硬依赖 libnuma（先试 stub 失败 → 编真实 numactl）；旧版
  rt-tests（v1.8）用 glibc 私有 `_sigev_un`（musl 无）；新版 cyclictest.c:59 的
  glibc 宏泄漏需 `#ifdef __GLIBC__` 本地 patch。

### T1.1 dedicated 核无 tick（✅ 代码 + ✅ 验证）
- **方法**：axruntime `set_dedicated_cpus(mask)`（opt-in 全局 static）；
  `advance_periodic_timer`/`program_next_timer`/`init_timer` 对 dedicated 核跳过
  周期逻辑（只留事件驱动 oneshot）；axvisor 从 host bootargs 解析
  `dedicated_cpus=`（axvm `host_bootargs()` 读 FDT chosen）。
- **验证**：日志确认 `Dedicated (no-tick) host CPUs: 0b10`。

### T1.2 RT 分区配置档（✅）
- **方法**：`ArmVcpuSetupConfig` 加 `trap_wfi`；`vm_placed_on_dedicated_cpus`
  （VM 全核 dedicated → HCR_EL2.TWI 清除，WFI 原地等待）；
  `rt-partition-zephyr.toml`（passthrough + 绑核 + 无 virtnet）。
- **坑**：`|=` 不适用于 tock_registers FieldValue（用 `+` 组合）。

### T2.1 调度抢占（⚠️ 最终态：协作式 + 无 ipi）
- **尝试 1**：sched-rr+ipi → **smoke 回归**（ESR 0x96000005 EL2 data abort 循环）。
- **尝试 2**：FIFO+preempt（无 RR）→ 仍回归。**结论**：ArceOS preempt 与 axvisor
  world-switch（IRQ 栈/上下文切换）不兼容，深层问题，诚实回退。
- **尝试 3**：仅 ipi → smoke/axtest/timer-stress 全过，但 **与 dedicated 组合导致
  enable 等待 50% 卡死**（CORES 计数不到 4，pCPU1 idle 唤醒依赖 IPI 而 IPI 路径
  有 race）→ 最终**去掉 ipi**（无 ipi + dedicated 4/4 稳定）。
- **保留**：`RT_TASK_PRIORITY=90` 标记三个关键任务（vCPU run/axvm-timer/injector），
  当前 FIFO 下是意图元数据（axsched set_priority 是 no-op）。

---

## 3. 失败/回退路径记录（重要教训）

1. **RR/preempt 与世界切换不兼容**：guest 运行时 EL2 IRQ → ArceOS preempt 检查 →
   任务切换破坏 world-switch 状态 → EL2 data abort。**未修复**（列为后续）。
2. **ipi + dedicated 组合卡死**：enable 阶段 50% 卡在 `while CORES != cpu_count`。
   无 dedicated 或 无 ipi 时 100% 正常。**根因未完全定位**（IPI 唤醒路径 race），
   通过去掉 ipi 规避。**待写文档**。
3. **debug 构建 3/4 核**：TCG 下 debug 慢，core1 的 enable 任务 5s 超时内没跑。
   **改用 release 构建解决**（0.76s 4/4）。
4. **serial socket 模式丢 guest 输出**：`-serial unix:` 下 Linux console 无输出，
   `-nographic` 正常。**实验统一用 -nographic**。
5. **guest DTB cpu reg 保留物理 id**：`[2,3]` 拓扑 Linux 完全无输出（Booting 都无，
   因 PSCI/console 依赖 DTB）。**根因**：need_cpu_node 过滤保留 host cpu 节点但
   reg 未重写。**已修**（renumber_guest_cpu_nodes + 回归测试）。
6. **bootargs 单参数误导**：曾误判"单参数 bootargs 全挂"，实为 RTMARKER123 测试
   标记污染 cmdline 注入（sed 破坏 TOML 引号）干扰了二分。
7. **isolcpus=1 导致 Linux 无输出**：曾归咎于 isolcpus，实为同一 DTB cpu reg 问题
   （隔离参数只是"压死骆驼的最后一根"）。isolcpus 未再验证（拓扑修复后未复测）。
8. **axvisor 必须用 .bin**：`-kernel` ELF 无输出（需 ELF→BIN 转换）。
9. **host bootargs 必须带 root=**：fs 构建下无 root= 则 root device 失败。
10. **Zephyr 与 Linux SPI 冲突**：passthrough 自动直通 vs Linux virtnet（48）——
   解决为 Linux virtualized（virtnet 模拟）+ Zephyr passthrough 独占直通。
   最新一次 serial 实验报 48 冲突（Zephyr 与 Linux 注册顺序 race）**待最终确认**。

---

## 4. 当前状态（会话末尾）

- 代码：11 commits，axvm 278 测试全过，clippy/fmt 干净。
- 实验：release 构建 + 无 ipi + dedicated_cpus=1 + 双 Guest 启动 ✅（rt-v3 验证：
  All cores / VM[2] boot success / Booting Linux）。
- **待解决**：Linux virtualized 的 virtnet0 与 Zephyr passthrough 的 SPI 48 冲突
  （serial 实验复现）；cyclictest 直方图采集；vmexit stat 前后对比数据。
- 未提交工作区：`rt-partition-zephyr.toml`（virtio 全 disabled 版）、
  `vm-aarch64-rt-linux.toml`（virtualized+virtnet 版）。

---

## 5. 实验证据与产物位置

| 产物 | 位置 |
|---|---|
| 工作日志（每任务问题/验证） | `results/task1/WORKLOG.md` |
| 抢救资产 + sha256 | `results/task1/virq-ab/` |
| 分配表 | `results/task1/allocation-table.md` |
| RT 配置（qemu/vm/board） | `scripts/test/rt-partition/` |
| 测量脚本（build/run/init/csv） | `scripts/test/rt-partition/` |
| 工具链源码（rt-tests/numactl/stress-ng） | `~/.local/src/` |
| guest 镜像暂存 | `tmp/rt-partition/` |
| 实验日志（会话内） | `/tmp/rt-*.log`（未归档，待正式实验重跑归档） |

---

## 6. 剩余 todo（完整清单，按优先级）

### T2.2 三组矩阵实验【进行中】
- [ ] 解决 SPI 48 冲突（Linux virtualized 的 virtnet 用 48 与 Zephyr 直通 48）
      —— 候选：Zephyr 排除 virtio（16 节点已列）+ Linux 用虚拟中断；
      或 Linux 不用 virtnet
- [ ] `vmexit stat` 采集：无 dedicated（≈100/s 定时器 exit，改造前基线）vs
      dedicated_cpus=1（≈0，改造后）→ `results/task1/exit-baseline/` +
      `results/task1/tick-isolation/`
- [ ] cyclictest 直方图确认（RT_CYCLICTEST_COMPLETE 后输出 `# Histogram`）
- [ ] 三组各 ≥30 分钟：① idle ② stress-ng 满载无隔离 ③ 满载+RT 分区
      → `results/task1/matrix/{idle,stress-noiso,stress-rt}/`（CSV+负载+sha256）

### T2.3 长时稳定性（1h，余力 8h）
- [ ] `results/task1/stability/`：时间漂移、max 劣化、vIRQ overflow 计数

### T3.1 过载/积压实验
- [ ] 注入周期 <100µs 或暂停 vCPU 制造积压，无界 vs 有界对比图
      → `results/task1/overload/`

### T3.2 vGIC EOI 即时重试核实
- [ ] 读 `arm_vgic/src/controller/...` 确认 LR 耗尽时是否已补注入
      （二选一：验证文档 或 接线代码+数据）

### T3.3 锁临界区文档化
- [ ] enqueue→notify 锁等待纳入 trace；死锁清单/锁次序纪律文档

### T3.4 native Zephyr 基线对比
- [ ] 构建 zephyr-periodic（Zephyr 源码需克隆，`~/.cache/zephyr` 只有缓存，
      west 已装，需 `git clone zephyr v3.7.0` + musl 交叉构建）
- [ ] 裸 QEMU vs RT 分区同口径对比 + 平台差异分析（TCG <50µs 不可信声明）

### T4.1 正式设计文档
- [ ] `book/design/task1-realtime-design.md`（对齐 task3-ai-design.md 模板）：
      全景延迟图 / 改造设计 / 分配表 / 数据引用 / 诚实局限
      （含：抢占回退、ipi+dedicated 卡死、TCG 限制）

### T4.2 results/task1 总索引 README
- [ ] 每个实验：目的/命令/时长/负载/数据文件/统计/sha256

### T4.3 本地提交（不合并 dev）
- [ ] 按改造单元拆本地提交（或保留现状 11 commits），分支最终态

### 待用户提供
- [ ] 实验机 `/tmp/ab-*.log`（T0.1 的 A/B 原始日志，311→301µs 复算）

### 已记录但未深入的问题（写文档素材）
- ArceOS preempt 与 axvisor world-switch 不兼容（T2.1）
- ipi 与 dedicated 组合 enable 卡死（T2.1/T1.1 交互）
- isolcpus/nohz_full/irqaffinity 未在拓扑修复后复测
- cyclictest 快速完成现象（-l 1800000 未按预期跑 30 分钟）——待查（可能
  cmdline 的 rt_loops 未传入，init 用默认值但应跑满）
