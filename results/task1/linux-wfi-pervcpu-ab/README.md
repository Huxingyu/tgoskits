# Linux per-vCPU WFI/timer contract A/B

## 结论

该实验验证了一个真正的软件关键路径候选，而不是静态 CPU 分区对比：
在相同 `dedicated_cpus=1,3`、相同 2-vCPU Linux、相同 Guest/Host 负载下，
唯一变量是 Linux VM 的 `aarch64_virtual_timer_only`。

- baseline (`false`)：Linux 可使用 CNTP，pCPU3 上 WFI 必须 trap，并通过
  AxVM software timer/park/wake 路径恢复运行。
- modified (`true`)：Guest 声明只使用 CNTV，pCPU3 可直接执行 WFI，由
  architectural virtual timer 直接唤醒。

机制消除成功，但实时性验收失败。三轮 modified 都把 pCPU3 WFI VM-exit
和 pCPU3 host timer IRQ 从数千次降为 0；与此同时 timerlat IRQ P99
三对均恶化，三轮中位数从 `897.744 us` 升到 `1502.064 us`，增加
`67.32%`。timerlat thread P99 中位数也从 `1523.952 us` 升到
`1887.952 us`，增加 `23.89%`。因此该能力保持显式 opt-in，Linux 模板
默认仍为 `false`，不能把退出次数归零表述为最坏延迟改善。

## 单变量与运行顺序

运行顺序为 `B1 -> M1 -> B2 -> M2 -> B3 -> M3`。共同条件：

```text
scenario=stress-dedicated
duration_sec=10
dedicated_cpus=1,3
linux_rt_cpu=1
linux_load_cpu=0
realtime_trace=timerlat
linux_trace_buffer_kb=256
runtime_diagnostics=1
Linux kernel SHA256=4a8fd8d2665a5a6e6e5f04c29ba3b44a5f6ff3f17bdb1d796d8ca4bf93705847
```

baseline 与 modified 的命令只在以下两项不同：

```bash
RT_LINUX_VIRTUAL_TIMER_ONLY=0  # baseline
RT_LINUX_VIRTUAL_TIMER_ONLY=1  # modified
```

每轮均启动 2-vCPU Linux（vCPU0/pCPU2、vCPU1/pCPU3）和并发 Zephyr VM；
pCPU1 与 pCPU3 的 Host periodic tick 在所有正式轮次均为 0。

## timerlat 结果

单位为微秒。`change` 为 modified 相对 baseline 的三轮中位数变化，负数
才表示延迟降低。

| metric | B1 | M1 | B2 | M2 | B3 | M3 | baseline median | modified median | change |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| IRQ P50 | 292.512 | 254.096 | 501.648 | 366.768 | 263.680 | 272.528 | 292.512 | 272.528 | -6.83% |
| IRQ P90 | 683.232 | 517.296 | 949.680 | 742.832 | 553.664 | 735.760 | 683.232 | 735.760 | +7.69% |
| IRQ P99 | 897.472 | 1502.064 | 1235.344 | 1580.896 | 897.744 | 1062.368 | 897.744 | 1502.064 | +67.32% |
| IRQ P99.9 | 1242.352 | 2712.656 | 1688.848 | 1915.488 | 1030.176 | 1588.192 | 1242.352 | 1915.488 | +54.18% |
| thread P50 | 584.944 | 530.928 | 791.856 | 623.168 | 513.856 | 545.120 | 584.944 | 545.120 | -6.81% |
| thread P90 | 987.664 | 936.352 | 1255.280 | 1217.216 | 1014.656 | 1138.000 | 1014.656 | 1138.000 | +12.16% |
| thread P99 | 1523.952 | 2005.536 | 1768.912 | 1887.952 | 1425.952 | 1623.760 | 1523.952 | 1887.952 | +23.89% |
| thread P99.9 | 1956.656 | 3368.000 | 2224.480 | 2669.504 | 2143.168 | 2097.024 | 2143.168 | 2669.504 | +24.56% |
| IRQ -> thread P99 | 1046.704 | 1157.856 | 917.232 | 1072.544 | 972.464 | 1143.568 | 972.464 | 1143.568 | +17.59% |

每轮约有 4650-4690 个 timerlat IRQ/thread 记录。IRQ P99 的逐对变化为
`+67.37%`、`+27.97%`、`+18.33%`，方向在三对中一致。

## 机制计数

| pair | baseline pCPU3 WFI | modified pCPU3 WFI | baseline pCPU3 host timer IRQ | modified pCPU3 host timer IRQ |
|---|---:|---:|---:|---:|
| 1 | 7875 | 0 | 6520 | 0 |
| 2 | 7291 | 0 | 6417 | 0 |
| 3 | 7819 | 0 | 6068 | 0 |

这组 L0 计数证明 direct CNTV/WFI 路径确实启用，且差异不是
`dedicated_cpus` 或 vCPU/pCPU 绑定变化造成的。它只证明路径被删除，不证明
被删除的路径是当前平台 P99 的主导项。

## 归档完整性

`M1`、`B2`、`M2`、`B3`、`M3` 的 `sha256sum -c sha256sums` 全部通过。
`B1` 的 Linux、Zephyr、timerlat 和最终诊断均完成，但旧版 cyclictest 在
quiet 模式下省略可选的 `# Histogram` 标题，旧解析器在最后归档阶段返回
2。因此 B1 的 raw log、timerlat 和 VM-exit 数据只作为一致性旁证；解析器
现已兼容有/无标题两种格式，并有回归测试。正式可校验对为 B2/M2 与
B3/M3。

## 后续决策

该候选不进入任务一的“最坏情况响应改善”数字。下一步应针对 timerlat
已经稳定暴露的 IRQ 到 RT thread 尾段，以及事件 trace 中
`sched_wakeup -> sched_switch` 的 P99 主导段；继续减少 WFI 退出不会自动
解决 Guest 调度尾延迟。
