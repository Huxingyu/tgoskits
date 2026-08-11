# Task-3 AI 控制闭环：工作记录与问题清单

> 更新：2026-08-11 22:40
> 分支：`openrace/task3-ai-control`（基于 Task-2 基线 `01f77307e`）

## 1. 总体进度

| 里程碑 | 状态 | 说明 |
|---|---|---|
| M0 基线/场景冻结 | ✅ | 分支、固定场景、参数快照（`task3-ai-control-todo.md`） |
| M1 Zephyr 虚拟对象 | ✅ | plant 整数语义与 Zephyr 逐点一致，扰动 8s/17s 生效 |
| M2 Linux 控制循环+baseline | ✅ | 100ms 周期（5-10Hz），1173 周期/104s/0 错误 |
| M3 模型训练+Rust 推理 | ✅ | DAgger 残差模型；golden 测试全过；Guest 内真实推理 |
| M4 AI/baseline 对比 | ✅ | 3+3 组 ×~39s，RMSE 29.3 vs 190.9 |
| M5 故障闭环 | ⚠️ 部分解决 | 运行时断链→Safe 已复现；恢复修复已实现，端到端验证待 Zephyr 重建（详见 §4.3） |
| M6 收口/文档/PR | ❌ 未开始 | 设计文档、证据归档、PR、回归 |

## 2. 已完成的证据（全部已提交）

- `6e8d6f3ce` Zephyr 虚拟对象（`TASK3_CONTROL_APPLIED`/`TASK3_PLANT_STATE`/`TASK3_DISTURBANCE`）
- `2758972c8` Linux 控制循环 + baseline P 控制器
- `907922205` build 脚本透传 `TASK3_CONTROL_LOOP`
- `465886183` M1/M2 收口：100ms 节流、`elapsed_ms` 日志、`task3_metrics.py`、baseline 证据（1173 周期、104.3s、0 错误）
- `6129adc44` M3+M4：`components/task3-model`（13,089 参数 CNN，0.7M MACs）、`scripts/task3/` 训练管线、AI/baseline 6 组实验数据（`results/task3/`）

**M4 核心结果（真实 QEMU 双 Guest）：**

| 指标 | AI (n=3) | baseline (n=3) |
|---|---|---|
| 整体 RMSE | 29.2 / 29.3 / 29.3 | 190.6 / 191.3 / 190.7 |
| t500 稳态误差 | ~2 | ~192 |
| Guest 内推理耗时 | 均值 11.3ms / p95 14.6ms | - |
| CONTROL→STATUS RTT | ~104ms | ~91ms |

## 3. 训练管线一览

```
plant.py            Zephyr 整数语义复刻（C 除法截断向零），与真实日志逐点验证
generate_dataset.py 400 随机 episode（目标阶梯/扰动/初值随机），94,800 样本，
                    标签=teacher 残差（gain=0.5 逆控制 − P 控制器输出）
train_model.py      初始 torch 训练（float32），导出 f64 权重 blob
dagger_train.py     6 轮 DAgger：真闭环 rollout（模型输出进 plant.step）+
                    teacher 打标 + 3 倍重采样，逐轮打印固定场景 RMSE
features.py         特征窗口唯一实现（64×4，target 通道恒定，prev_output 逐步历史）
export_golden.py    生成 Rust golden 测试（卷积 1e-9 / 窗口 1e-12）
components/task3-model  no_std 纯 Rust f64 前向，权重 include_bytes 嵌入
```

## 4. 遇到的问题与解决（重要）

### 4.1 设计阶段问题

1. **第一版 teacher（gain=1.0 一步到位逆控制）闭环振荡发散**
   - 原因：完美一步跟踪是 bang-bang 策略，模型无法在闭环中稳定模仿；且早期 target 特征通道与部署不一致。
   - 解决：teacher 改 gain=0.5 跟踪策略；target 通道整窗填当前值。

2. **float64 训练过慢（30 分钟超时白跑）**
   - 原因：CPU 上 float64 卷积 + 60 epochs + 大数据集。
   - 解决：训练用 float32，导出/黄金对照用 float64（两处精度都锁定）。

3. **初版 DAgger 不是真闭环**
   - 原因：`closed_loop_samples` 用了 episode 预计算的 P 轨迹状态，模型输出从未反馈进 plant——数据分布仍是 P 轨迹，DAgger 失效。
   - 解决：重写为逐 100ms `plant.step` 真 rollout，模型输出决定下一个状态。

4. **纯模仿（残差前）在闭环仍不稳定**
   - 原因：模型直接输出完整控制律，误差在非线性 plant 上放大。
   - 解决：改**残差学习**——模型只学 P 控制器缺失的损耗/扰动补偿项，P 项保证闭环稳定。固定场景 RMSE 从 189 → 33。

### 4.2 实现阶段问题（测试抓到的 bug）

5. **Rust 卷积 kernel 镜像 bug**
   - 现象：golden 测试 case 2（斜坡输入）输出 0.12 vs 参考 0.83。
   - 原因：`t_padded = t + PAD - k` 写成镜像卷积；全 0/全常数输入恰好测不出。
   - 教训：**golden 测试的输入必须有非对称模式**（斜坡），否则镜像/翻转类 bug 会漏网。已修复。

6. **prev_output 特征前后不一致**
   - 现象：训练数据集该通道是"逐步输出历史"，DAgger/评估填的是"当前常量"，Rust 部署又是一种。
   - 根因：特征窗口构造在 4 处各写一遍，迭代中约定漂移。
   - 解决：`features.py::build_window` 唯一实现，Python 全端复用；Rust `build_features` 镜像 + golden-window 测试（1e-12）跨语言锁死。
   - 教训：**动手前冻结"特征契约"并用跨语言测试锁住**，而不是事后对齐。

7. **Guest 内模型修正量恒为 0（×1000 缩放缺失）**
   - 现象：AI 运行轨迹与 baseline 完全一致（RMSE 190）。
   - 原因：模型输出是归一化尺度（label/1000），Rust 端直接加进 0..1000 控制值，忘乘 1000。
   - 解决：`correction = forward(&features) * 1000.0`；重跑后 RMSE 190 → 29.3。

8. **残留 QEMU 进程占 12721 端口**
   - 原因：实验脚本超时退出时 nohup 的子进程没被杀。
   - 解决：脚本入口 `pkill` 清理 + 退出兜底。

### 4.3 M5 受阻：QMP `set_link` 运行中切不断流量

- 实测（2026-08-11 深夜复现）：`set_link net-linux off` **连开机前置 down 都切不断数据**——双方仍互收心跳并自动恢复，早前的 Safe 只是启动时序（对端未就绪→重传耗尽）造成的假象；`netdev_del` 能真正切断（双方 RetryExhausted/HeartbeatTimeout 进 Safe）但无法恢复（listen 端口不释放、NIC 仍挂旧 peer，`netdev_add` 报 Address already in use）。
- 解决（已提交 `dea4f5dd2`）：改用 **P3 代理黑障**——`ack_drop_proxy.py` 新增 `--blackout-start-ms/--blackout-duration-ms`，在真实 guest 链路中间按时间窗口丢弃全部帧，窗口结束自动恢复转发；`run-task3-fault.sh` 重写为 P3 拓扑 + 黑障，并修复 `wait_for` 匹配旧日志行的缺陷（改为只扫新增行）。
- 恢复路径又发现并修复两个真 bug（`9eba59446`）：
  1. 控制器进 Safe 时 `request_in_flight` 未清，`TASK2_RECOVERED` 补发被早退吞掉 → 请求-响应循环永远不续跑；现于 RetryExhausted/HeartbeatTimeout 时复位。
  2. Safe 恢复后可靠流序号分歧：managed 侧丢失的 STATUS 已重传耗尽、下一条是 n+1，controller 仍期望 n → `out_of_order` 死循环；Rust 协议与 Zephyr C 均在 Safe→Active 时把 `next_tx/next_rx/pending` 重置，重新从序号 1 同步（含 Rust 回归测试）。
- **当前阻塞**：Zephyr C 修复已写好，但本环境 `/tmp/zephyrproject/zephyr` 与 `/tmp/zephyr-sdk` 已清理且网络不通，无法重建 `zephyr-task2.bin`；端到端"恢复后控制环续跑"需在具备 Zephyr 工具链的机器上 `bash scripts/test/net-dual-guest/build-zephyr-task2.sh` 后重跑 `bash scripts/task3/run-task3-fault.sh` 验证。

## 5. 遗留工作

1. **M5 收尾**：在具备 Zephyr 工具链的机器重建 Zephyr（`build-zephyr-task2.sh`，含 §4.3 的 C 侧重同步修复），重跑 `run-task3-fault.sh` 验证"黑障→Safe→恢复→控制环续跑"，归档 AxVisor 日志 + 两侧 pcap 到 `results/task3/fault/`。
2. **M6**：
   - 编写 Task-3 设计文档（SIL 边界、不声称硬实时）；
   - 归档：模型结构/权重哈希（`model.json`）、6 组 CSV、`comparison.png`、构建/运行命令；
   - 更新 `task3-ai-control-todo.md` 全部勾选；
   - 单独 Task-3 PR（英文标题/中文正文，含问题、改动、每步逻辑）；
   - Task-2 回归（`cargo test -p task2-net-protocol`、verify 脚本）。

## 6. 复现命令

```bash
# 训练（固定 seed）
python3 scripts/task3/generate_dataset.py --train-episodes 400 --val-episodes 40
python3 scripts/task3/train_model.py --epochs 60
python3 scripts/task3/dagger_train.py --iterations 6 --epochs 25 --closed-loop-weight 3
python3 scripts/task3/export_golden.py && cargo test -p task3-model

# 构建 guest（baseline / AI）
TASK3_CONTROL_LOOP=1 bash scripts/test/net-dual-guest/build-linux-task2.sh
TASK3_CONTROL_LOOP=1 TASK3_AI=1 bash scripts/test/net-dual-guest/build-linux-task2.sh
bash scripts/test/net-dual-guest/build-linux-initramfs.sh

# 实验（每组 ~39s 闭环）
bash scripts/task3/run-task3-experiment.sh ai-runX ai
bash scripts/task3/run-task3-experiment.sh baseline-runX baseline
# 故障（M5，开机前置 down）
bash scripts/task3/run-task3-fault.sh fault-runX

# 指标
python3 scripts/test/net-dual-guest/task3_metrics.py <logs...> \
  --out-dir results/task3 --label run --modes ai,ai,ai,baseline,baseline,baseline \
  --plot results/task3/comparison.png
```

## 7. 诚实声明（M6 文档将重申）

- 所有结论基于 QEMU SIL 验证，不声称真实板卡或硬实时保证；
- 冻结场景外推有限：模型只在随机化训练分布上验证；
- t800 目标（800）超过 plant 可持续上限（~760，含 +150 扰动 ~880），AI 以 ~790-810 逼近而非达到；
- baseline 为 M0 冻结的 Kp=2 纯 P 控制器，非故意调差；
- M5 断链通过 P3 代理黑障实现（真实 guest 链路全帧丢弃），非 QEMU `set_link`；恢复路径修复已实现，端到端验证待 Zephyr 重建后补跑。
