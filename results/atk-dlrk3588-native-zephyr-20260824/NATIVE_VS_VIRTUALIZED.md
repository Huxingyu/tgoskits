# ATK-DLRK3588 原生、单 Guest 与双 Guest Zephyr 对比

日期：2026-08-24

## 结论

此前 Task 1 的“原生 RTOS 基线”只有 QEMU 证据，缺少 RK3588 物理板原生数据。本轮已在同一块 ATK-DLRK3588 上补齐原生 Zephyr 物理 baseline：300 个 10 ms 周期样本连续完成，无丢样、无超 1 ms 样本、无 10 ms deadline miss。

该证据支持把内部评分表中的“原生 RTOS 基线”从保守 `4/5` 更新为目标 `5/5`。官方最终得分仍由评审决定。

## 可比口径与版本边界

- 板卡：所有物理臂均为 ATK-DLRK3588 / RK3588；
- 原生和新补单 Guest 均使用 Zephyr commit `dccb09599635bdff17633fa7e9dab014b91dce90`；
- 单 Guest 与统一双 Guest 对照臂嵌入完全相同的 `zephyr-task2.bin`，SHA256 为 `ff316057f7fd829cdcd059f9fb7729bef0f877b8e2e486fbdb547bd3a6fe2522`；
- 原生使用独立 periodic 应用，单/双 Guest 的统一镜像还包含网络端点线程，所以原生到单 Guest 是端到端近似，而不是微架构级纯虚拟化 A/B；
- 此前两轮正式 RR/FP-RR 日志实际报告 Zephyr build `36940db938a8`，并非 `dccb095...`。它们只作为历史调度趋势，不能与新单 Guest 合并为严格同版本 A/B；
- 系统 tick：1000 Hz；
- 周期：10 ms，使用 absolute tick deadline；
- 样本：每轮 300 个，采样窗口约 3 秒；
- 时钟：`k_cycle_get_64()`，统一换算为 ns；
- 采样窗口内不打印，窗口结束后导出 CSV。

## 实板结果

native 是无虚拟化、无并发 YOLO 的物理基线。新单 Guest 臂没有第二个 Guest；统一双 Guest 臂使用与单 Guest 完全相同的 `ff316057...` Zephyr，并在 StarryOS 中执行一次真实 YOLO。最后两行是旧 Zephyr build 的两轮历史 median，仅用于保留 RR/FP-RR 调度趋势。

| 模式 | 轮次 × 样本 | P50 | P95 | P99 | P99.9 / max | >1 ms | >10 ms |
|---|---:|---:|---:|---:|---:|---:|---:|
| 原生 Zephyr | 1 × 300 | 0.002041 ms | 0.002041 ms | 0.002041 ms | 0.004000 ms | 0 | 0 |
| AxVisor FP-RR 单 Zephyr Guest | 1 × 300 | 0.063312 ms | 0.064336 ms | 0.069120 ms | 0.069600 ms | 0 | 0 |
| AxVisor FP-RR 双 Guest，同一 `ff316057...` Zephyr + 一次真实 YOLO | 1 × 300 | 0.198272 ms | 0.238400 ms | 0.506976 ms | 2.490048 ms | 1 | 0 |
| 历史 FP-RR 双 Guest，旧 Zephyr `36940db...` + sustained YOLO | 2 × 300 | 0.088224 ms | 0.104536 ms | 0.117200 ms | 1.746608 ms | 1 | 0 |
| 历史 RR 双 Guest，旧 Zephyr `36940db...` + sustained YOLO | 2 × 300 | 1.997840 ms | 5.121984 ms | 5.291696 ms | 6.498808 ms | 229 | 0 |

原生侧完整统计：

```text
samples=300
runtime_ns=3000002041
min_ns=2041
mean_ns=2047.53
p50_ns=2041
p90_ns=2041
p95_ns=2041
p99_ns=2041
p99_9_ns=4000
max_ns=4000
over_1ms=0
over_10ms=0
sequence_errors=0
monotonic_errors=0
```

新单 Guest 的 P99 为 `69.120 us`，约为原生的 `33.87×`。使用完全相同 Guest 二进制的统一双 Guest 臂为 `506.976 us`：第二个 Guest 加一次真实 YOLO 在单 Guest 基础上增加 `437.856 us`，即 P99 提高约 `633.5%`。历史旧版本数据仍显示，在相同旧 Guest 与 sustained YOLO 条件下，FP-RR 相对 RR 将 P99 从 `5.292 ms` 降至 `0.117 ms`，下降约 `97.8%`。

## 解释边界

这组数据回答两个不同问题：

1. 原生物理 baseline 证明 RTOS/板卡自身能把 10 ms 周期唤醒控制在微秒级；
2. 单 Guest 证明即使没有第二个 Guest，当前虚拟定时器、中断和 Host 调度链路仍有明显固定开销；
3. 同一 Guest 二进制的单/双 Guest 对照证明共享 pCPU 和真实 YOLO 会进一步显著放大尾延迟；
4. 历史 RR 与 FP-RR A/B 证明 AxVisor 实时调度改造在相同旧版本虚拟化负载下显著降低尾延迟。

新单 Guest 已补齐 Zephyr-only、同 pCPU、无 YOLO 控制臂。但由于原生是独立 periodic 应用，统一 Guest 还带一个空闲网络端点线程，原生到单 Guest 的 `33.87×` 仍应称为“接近虚拟化固定开销的端到端差距”，不能表述为纯 hypervisor 指令级开销。严格的竞争增量应看同一 `ff316057...` Guest 的单/双 Guest 对照。

## 证据位置

- 原生完整串口：`logs/native-periodic-console.log`
- 原生 CSV：`analysis/native-periodic.csv`
- 多模式汇总：`analysis/native-vs-virtualized.csv`
- 单 Guest 和历史虚拟化原始报告：保存在外部 2026-08-24 实验归档中；本目录的
  `analysis/native-vs-virtualized.csv` 保留本报告引用的汇总值
- 原生应用：`../../scripts/test/native-zephyr-atk-dlrk3588/`
- 原生 BL33：由上述应用构建脚本生成，不作为二进制提交
- 原生启动与调试结论：`../../docs/docs/debug/rk3588-native-zephyr-bringup.md`

关键 SHA256：

```text
native zephyr.bin  5a22dec9b3b8f92f8b2ea9c5228c571236b2ae37b38300513d472622f212be4c
native BL33        59ef4dd3ffab6a0d767755cc3822d67a5047cfa227c338e2312fa062ff01fd1d
native CSV         c06f4210f2f492b632b4682834a474a43815db35638b07e9e03d5b1db05cab2f
native console     aecc928fafd74ca625406deba47520a320c5ad16c4124af5250f5e2f0df4bd81
```
