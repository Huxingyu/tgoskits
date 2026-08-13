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

## T0.2 per-CPU exit-reason 计数器【未开始】

## T0.3 vMPIDR 与物理放置解耦【未开始】

## T0.4 多核 Linux 客户机配置【未开始】

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
