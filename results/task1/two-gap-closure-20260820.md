# Task 1 两个缺口的闭环报告（2026-08-20）

本报告对应任务一评审中最容易丢分的两个问题：

1. Linux vCPU 与 RTOS vCPU 是否真的在同一个 pCPU 上竞争，以及实验收尾
   是否可靠；
2. IRQ 返回尾部抢占是否真正接入了 AxVisor 的内部关键路径，同时避免把
   每个普通 IRQ 变成一次无界调度。

## 一、共核实验：从“能启动”到“可复现闭环”

### 拓扑和变量

```text
Linux vCPU0  ─┐
              ├── pCPU1（直接竞争）
Zephyr vCPU0 ─┘
Linux vCPU1 ───── pCPU2（Linux housekeeping）
```

`dedicated_cpus=none`，没有 host burner；RR、Fixed FIFO、FP-RR 只替换
AxVisor scheduler feature，Guest 镜像、内存、设备和 IRQ 路由保持不变。
这排除了“静态分区带来收益”的解释。

### 原失败原因

Linux cyclictest 完成后立即 `PSCI_SYSTEM_OFF`，而 Zephyr 在 QEMU TCG 下
可能尚未完成。runner 随后尝试重新 attach Linux，得到：

```text
VM[1] is not running
```

另一个隐蔽因素是旧的 `rt-linux-initramfs.cpio.gz` 没有重新打包，磁盘上的
脚本已经更新但 Guest 仍在运行旧逻辑。

### 修复

```text
Linux complete
→ RT_CYCLICTEST_HOLD_READY
→ runner 收集 Linux/Zephyr/VM-exit 证据
→ runner 发送 release
→ RT_CYCLICTEST_RELEASED
→ Linux PSCI_SYSTEM_OFF
```

runner 还改为在 Zephyr 完成后显式选择 `cmd vm console 1`，并在采样窗口
前、Zephyr 完成后、最终退出前保存三次 VM-exit snapshot。构建命令必须先
执行：

```bash
scripts/test/rt-partition/build-rt-tools.sh
```

### 当前闭环证据

| 策略 | 证据目录 | Linux avg / P99 / max | Zephyr P99 / max | 结果 |
|---|---|---:|---:|---|
| RR | `results/task1/irq-tail-priority-filter-rr-smoke-20260820/stress-guest-shared/` | 1,961 us / 7,142 us / 310,639 us | 31.582 ms / 67.259 ms | accepted |
| FP-RR | `results/task1/irq-tail-priority-filter-smoke-20260820/stress-guest-shared/` | 2,170 us / 19,549 us / 349,196 us | 35.632 ms / 145.725 ms | accepted |

两个目录均有 3000/3000 Zephyr 样本、Linux histogram、CPUStat、VM-exit
快照、hold/release marker 和正常 QMP 退出。数字受 TCG 运行时调度影响，
这里的核心结论是“同一 pCPU 的竞争确实发生且测试可收尾”，不是宣称每个
百分位都改善。

## 二、IRQ 尾部抢占：从失败反例到条件化实现

### 机制缺口

GIC 在 AxVM 中已经完成 acknowledge，原 host dispatch 直接调用动态 IRQ
框架，绕过了 AxHAL 的统一 IRQ-entry/preemption-release 边界。因此 IRQ
handler 唤醒高优先级 vCPU 后，VM-exit 返回点不一定消费 `need_resched`。

### 为什么不能“每个 IRQ 都抢占”

两版实验已经给出反证：

- completion 放在调度边界之后：Linux P99 撞到 20 ms histogram ceiling；
- completion 虽移入 guard，但每个 acknowledged IRQ 都允许尾部调度：Linux
  约 258 个样本后停滞，`slice_preserving_preemptions=78906`、
  `voluntary_requeues=6128290`。

根因是 timer/console IRQ 风暴产生同级 vCPU 的重复切换，而不是单纯的
“优先级算法不够快”。失败目录保留在
`results/task1/irq-tail-preemption-*-20260820/`。

### 当前实现

1. `axhal::irq::dispatch_acknowledged_irq` 接收已经 acknowledge 的
   `IrqId` 和 caller-owned completion closure；不二次 acknowledge。
2. dispatch 后先执行 GIC deactivate/EOI，再撤销 IRQ context、释放
   preemption guard，保持普通硬件 IRQ 的返回顺序。
3. AxVM GIC 只负责解析 token 并提供 completion；路由和所有权不变。
4. 固定优先级模式下，IRQ context 中只有“唤醒任务优先级严格高于当前任务”
   才设置 `need_resched`；CPU 正在 idle 时保留唤醒例外。RR/FIFO 路径保持
   原行为。

### 验证结果

```text
cargo check -p ax-hal -p ax-task -p axvm                 PASS
cargo test -p ax-sched                                   20 passed
cargo test -p ax-task --features test,smp,sched-prio-rr  53 passed
cargo test -p ax-hal --features axtest,host-test         4 passed
Python rt-partition tests                                 55 passed
真实 QEMU RR/FP-RR 共核 smoke                              均 accepted
```

真实 smoke 的共同 marker 顺序为：

```text
PERIODIC LATENCY COMPLETE samples=3000
RT_CYCLICTEST_COMPLETE
RT_CYCLICTEST_HOLD_READY
RT_CYCLICTEST_RELEASED
PSCI_SYSTEM_OFF
```

## 最终边界

这两个问题现在都已完成“根因解释 + 代码修复 + 真实运行验证 + 失败证据
归档”。可以提交的硬结论是：

- 共核拓扑是实际共享 pCPU，不是静态分区；
- Linux 收尾 race 已修复，结果采集有明确 hold/release 协议；
- acknowledged IRQ 的 completion 顺序已修正；
- IRQ 尾部抢占改为优先级条件化，旧的 Linux 停滞不再复现。

仍需保守表述：QEMU TCG 下 P99/P99.9 会有明显波动；没有据此声称所有
指标改善，也没有把 QEMU 结果等同于物理 RK3588 的最坏情况保证。
