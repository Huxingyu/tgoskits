# Task-3 证据归档

> 分支 `openrace/task3-ai-control`；设计文档见 `book/design/task3-ai-design.md`。

## 指标与对比（M4）

| 文件 | 内容 |
|---|---|
| `run-{1..3}.csv` | AI 模式原始日志 CSV |
| `run-{4..6}.csv` | baseline 模式原始日志 CSV |
| `summary.csv` | 逐组 RMSE/调节时间/超调/RTT 汇总 |
| `comparison.png` | AI vs baseline 响应曲线对比图 |

核心结论：整体 RMSE AI 29.2–29.3 vs baseline 190.6–191.3；t500 稳态误差
~2 vs ~192；Guest 推理 11.3 ms 均值 / 14.6 ms p95。

## 故障闭环（M5）

| 文件 | 内容 |
|---|---|
| `fault-final3-*.log` / `fault-final4-*.log` | guest + proxy 日志（黑障→Safe→恢复→续跑） |
| `fault-final3-*pcap` / `fault-final4-*pcap` | 双端数据面抓包 |
| `fault-final3.sha256` / `fault-final4.sha256` | 上述证据哈希 |

关键事件：黑障 25s→35s（代理丢 102 帧）→ 双方 Safe → 恢复 → 控制环续跑
（final4 恢复后 82 个 STATUS 周期、0 错误）。

## 模型（M3）

模型结构/权重哈希/训练器哈希见
`components/task3-model/model/model.json`（13,089 参数，~0.7M MACs，
`weights.bin` SHA-256 内联记录）；golden-vector / golden-window 测试随
`cargo test -p task3-model` 可复算。

## YOLO 感知补充

`results/task3/yolo/` 保存了 YOLO11n ONNX 的固定图片 fixture 结果。它验证
模型 hash、YOLOv8-style 输出解码、置信度/面积门限、中心位置到控制目标的
有界映射，以及低置信度无检测时的安全拒绝。运行命令和当前结果见该目录
的 README 与 `yolo-fixture-manifest.json`。

当前 AArch64 Guest 通过 `TASK3_MODEL=yolo` 使用一个确定性的 fixture replay
adapter：它重放同一 manifest 中的无检测、正常检测和大步长检测，并通过
`task3_model::perception` 的置信度/面积/坐标/单帧步长边界后再产生 CONTROL。
这验证了 YOLO 感知结果进入 T2N1 控制链路的安全接线；它仍不是 Guest 内的
ONNX runtime，fixture replay 的推理耗时不能当成真实 YOLO 推理性能。

编译时选择模型（默认行为保持兼容）：

```bash
TASK3_CONTROL_LOOP=1 TASK3_MODEL=cnn \
  bash scripts/test/net-dual-guest/build-linux-task2.sh
TASK3_CONTROL_LOOP=1 TASK3_MODEL=yolo \
  TASK3_MODEL_PATH=embedded:fixture-replay \
  TASK3_YOLO_MIN_CONFIDENCE_MILLI=600 \
  TASK3_YOLO_MIN_AREA_MILLI=10 \
  TASK3_YOLO_MAX_TARGET_STEP=100 \
  bash scripts/test/net-dual-guest/build-linux-task2.sh
```

controller 日志会输出 `TASK3_MODEL_READY`、`TASK3_DETECTION`、
`TASK3_MODEL_REJECTED`、`TASK3_INFER` 和带模型名的 `TASK3_CONTROL_SENT`。
当前 `yolo` 适配器只接受 `TASK3_MODEL_PATH=embedded:fixture-replay`；传入
其他路径会显式失败，避免把缺失的 ONNX 文件误报成 Guest 内推理。

## 构建与运行命令

见 `book/design/task3-ai-design.md` §8。
