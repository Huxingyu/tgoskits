# 两个缺口实验复核（2026-08-20）

> **历史记录说明（2026-08-21）**：本文记录的是无条件 IRQ-tail 和旧收尾
> race 的失败复核，不能作为当前实现状态。当前优先级感知 IRQ-tail、GIC
> completion 顺序和 Linux hold/release 收尾已经完成，正式结论见
> `results/task1/two-gap-closure-20260820.md` 与
> `results/task1/irq-tail-preemption-design.md`。本文保留为负面证据，避免把
> 旧失败结论误读为当前代码仍未接入。

## 1. IRQ 返回尾部抢占

本轮没有把“每个已确认 GIC IRQ 都在返回尾部统一调度”重新接回默认路径。此前两版实现已经完成了机制验证但均未通过稳定性门禁：第一版使 Linux P99 撞到 20 ms 直方图上限；第二版虽然先完成 GIC deactivate 再释放 IRQ/preempt guard，但 Linux 约 258 个 cyclictest 样本后停滞，统计出现约 78,906 次 slice-preserving preemption 和约 6.1M 次 voluntary requeue。

因此当前结论是：

- 方向成立：AxVM GIC raw dispatch 确实绕过了 AxHAL 的统一 IRQ-return 调度边界；
- 无条件尾部抢占不可接受：普通 timer/console IRQ 也会触发重复调度；
- 默认代码保持 raw dispatch，失败目录保留为反证：
  `irq-tail-preemption-smoke-20260820/`、
  `irq-tail-preemption-complete-before-resched-smoke-20260820/`；
- 下一版必须只在“新唤醒了更高优先级 vCPU”且通过切换频率限流时请求调度，并保证 GIC deactivate/EOI 先完成。

回滚后的代码检查：AxHAL/AxVM 24 项 clippy 全部通过，AxVisor AArch64 release build 通过。

## 2. RR 与 bounded FP-RR 共核 A/B

协议：Linux vCPU0 与 Zephyr vCPU0 绑定同一 pCPU1，Linux vCPU1 绑定 pCPU2；关闭 dedicated CPU 与 host burner；唯一变量为 `rr-scheduler` / `rt-scheduler`。本轮按 2 个 30 秒运行配置启动（每个 3000 Zephyr samples），但首个 RR 变体就在收尾阶段卡住，实际只完成了首轮 RR，未启动第二个变体；输出目录：

`results/task1/shared-core-ab-rerun-20260820/`

RR 首轮成功启动并完成 Zephyr 3000 samples，但 runner 在 Linux 收尾阶段未获得完整 Linux cyclictest summary，停留在反复 attach/detach VM[2] console。该轮因此被判为**实验失败**，不能纳入性能统计。日志最后包含 `PERIODIC LATENCY COMPLETE samples=3000`，但没有正式 summary；没有启动第二个变体，避免把不对称失败伪装成 A/B 结果。

可用的正式证据仍是此前归档的 3 轮 FP-RR ABABAB 结果：Zephyr P99 中位数约 `10.721 ms -> 1.022 ms`（约 10.49 倍），但这是已有稳定实验，不是本次复核的新统计。当前 QEMU TCG/串口收尾路径仍表现出显著不稳定，短跑失败本身应作为稳定性限制记录。

## 结论

本轮“尝试”完成了两个缺口的受控复核：IRQ 尾部抢占不能按无条件方式交付；共核 A/B 入口可启动并完成 Zephyr，但 Linux 收尾门禁失败。没有新增可合法宣称的性能提升数字，也没有把失败运行混入正式结果。
