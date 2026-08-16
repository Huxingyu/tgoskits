# P1 共核竞争与 RT 分区交错对比

## 结论

在 3 组 ABABAB 交错短窗实验中，Zephyr 10 ms 周期唤醒的 P99 jitter
中位数从 17.054 ms 降到 0.932 ms，改善 18.29 倍。两组区间完全分离：
官方基线的最好一次仍为 12.414 ms，修改后的最差一次为 1.003 ms。

这个结论仅描述通过完整验收的运行。整批 11 次启动尝试中只有 6 次通过，
说明 SMP 启动和 dedicated vCPU 唤醒仍有严重的 liveness 问题；重试没有修复
该架构缺陷，失败率必须与性能结果同时报告。

## 对比边界

- baseline：官方 `upstream/dev@7786159aced92d984842855a834b8190676a0422`
  加与修改分支相同的 benchmark burner；virtualized Zephyr 与 burner 共用 pCPU1，
  不设置 dedicated CPU。
- modified：`openrace/task1-rt-partition@619ab6c6dd9ebbd6557f4828cecaea3ab82dd203`；
  virtualized Zephyr 仍在 pCPU1，但 pCPU1 设置为 dedicated/no-tick，burner 移到 pCPU0。
- 两边 Linux 均位于 pCPU2/3，运行相同 stress-ng 与 cyclictest 工作负载。
- 两边 Zephyr 镜像 SHA-256 均为
  `402e0b6afeba044b6c407f8e02caffe668ab372df30831fc3dd67c9fbd2654db`。
- burner 源码在两个 worktree 中逐字节相同，参数均为 10 ms busy、53 ms idle、
  启动延迟 60 s。Zephyr 在 gate 后等待 45 s，保证采样发生在 burner 活跃窗口。
- 每次 Linux 窗口为 90 Guest 秒；Zephyr 采集 300 个 10 ms 周期样本。

benchmark burner、gate settle 和统计脚本属于两边共同的测量 enablement，不能计入
RT 改造收益。真正的对比变量是同驻负载是否与 Zephyr 共核，以及 pCPU1 是否执行
dedicated/no-tick 策略。

## 硬指标

| 指标 | 官方 DEV 共核基线，中位数 [min, max] | 修改后 RT 分区，中位数 [min, max] |
|---|---:|---:|
| P99 jitter | 17.054 ms [12.414, 18.960] | 0.932 ms [0.764, 1.003] |
| P99.9 jitter | 22.321 ms [19.153, 27.002] | 1.015 ms [0.802, 1.153] |
| observed max | 22.321 ms [19.153, 27.002] | 1.015 ms [0.802, 1.153] |
| 1 ms 容差 miss / 300 | 111 [100, 141] | 1 [0, 4] |

P99 中位数改善倍数为 18.291；按 AB 顺序逐对计算的改善倍数中位数为 20.336。
这是 QEMU TCG 上的受控相对对比，不是形式化 WCET，也不代表物理板绝对延迟。

## 启动与唤醒可靠性

| 变体 | 有效运行 | 总尝试 | 失败尝试 | 单次尝试通过率 |
|---|---:|---:|---:|---:|
| baseline | 3 | 7 | 4 | 42.9% |
| modified | 3 | 4 | 1 | 75.0% |
| 合计 | 6 | 11 | 5 | 54.5% |

失败均发生在结果验收之前，不进入延迟统计。观察到两类失效：官方基线在全部 host
CPU 宣告虚拟化初始化完成后仍未启动 default VM；修改后有一次在 Zephyr 进入
45 s settle 后未被定时器重新唤醒。这些现象与当前协作式 FIFO 下的 wake-before-wait
竞态相符，但还需要针对启动状态机和 per-vCPU wake token 的 trace 才能完成根因闭环。

## 证据

- `comparison.txt`：3 次重复的中位数、min/max 与改善倍数。
- `reliability.txt`：每个有效 run 使用的尝试次数与总通过率。
- `baseline/run-*/stress-noiso/`：官方 DEV 共核运行的完整归档。
- `modified/run-*/stress-dedicated/`：修改后 dedicated 运行的完整归档。
- `../p1-interleaved-2026-08-16.batch.log`：所有成功和失败尝试的原始编排日志。
