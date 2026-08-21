# OpenRace 最终收口与 Task3 模型扩展 TODO

> 目标：在不继续扩大 Task1 调度机制范围的前提下，完成最终提交收口，
> 补齐 Task2/Task3 的可交付证据，并为 Task3 增加可复现的 YOLO 感知模式。
>
> 当前基线：Task1 提交保守自评 26–27/30（28/30 为乐观上限），Task2
> 24/25，Task3 25/25，工程完整性 9/15。分数是内部估计，不是官方最终评分。

## 执行原则

- 每个阶段必须有代码或文档产物、验证命令和可定位的证据目录。
- 只提交本阶段相关文件；保留工作区中其他实验产物，不做清理性覆盖。
- 每完成一个可独立审查的阶段，就运行相应验证，创建 Conventional Commit，
  并推送到对应的 `openrace/*` 远程分支。
- Task1 只做证据、文档和提交收口；除非新实验能直接补足缺失的一分，
  不再增加新的调度机制。

## 当前优先级（2026-08-21）

1. **最终文档与交付包**：统一 Task1/Task2/Task3 的证据索引、命令、哈希、
   历史文档标识和演示流程。这是当前最确定的主评分收益。
2. **Task2 缺口**：补 `session-mismatch ERROR` 互操作回归、默认 xtask/CI
   入口，并在当前 HEAD 重采集网络证据。
3. **StarryOS/STERRORS 路径**：优先做能形成可观察闭环、并能合入官方 `dev`
   的 syscall/替代 Guest 改造；单纯启动不算完成。
4. **第二种 RTOS 或第二块板卡**：已有路径稳定且成本可控时再做，最多争取
   2 个加分，不阻塞主线。
5. **Task1 补充实验**：只有在低成本且能直接补齐一项可比最坏情况数据时执行；
   不重新扩大调度机制探索。

因此，Task1 当前按“已完成主要机制、保留证据限制、冻结范围”处理，不再作为
最高优先级开发线。

## 阶段 0：当前状态冻结（已完成）

- [x] 同步 Task1 两个缺口报告的测试数量：`ax-task` 为 56 passed。
- [x] 归档共核实验的 hold/release 协议、IRQ completion 顺序和优先级条件化
      抢占的失败证据与修复边界。
- [x] 明确 Task1 当前交付边界：QEMU 软件在环证据，不宣称物理板 worst-case。

## 阶段 1：最终文档与提交收口（高优先级）

- [x] 将 Task2 canonical 设计/运行摘要和本评分表纳入最终分支。
- [x] 给 Task1 旧设计、失败复核和历史统计文档加上 `historical` 标识，
      避免旧数字与最终数字混用。
- [x] 在当前最终 HEAD 上复跑一次 Task2 网络 + Task3 AI 闭环；YOLO
      双 Guest 运行、双端 pcap 和 QMP 正常退出证据见
      `results/task3/switch/current-head-yolo-capture/`。
- [x] 在当前 HEAD 重跑协议/模型 contract gate、YOLO fixture，并重建 YOLO
      Linux endpoint、initramfs 和 Zephyr managed Guest；完整命令、hash 和
      pcap 见 `results/task3/yolo/current-head-validation-20260821.md`。
- [ ] 统一构建、启动、验证命令及 SHA256 manifest。
- [ ] 检查 Task2/Task3 与 `dev` 的冲突，创建可审查的 Task1/Task2/Task3 PR。
- [ ] 准备官网要求的约 5 分钟演示流程和日志 marker 清单。

验收：新环境按文档能构建并运行；结果目录能由命令唯一定位；没有引用
已经被新提交淘汰的旧统计。

## 阶段 2：Task2 缺口（高优先级）

- [x] 增加 Linux/RTOS `session-mismatch ERROR` 的互操作回归；Heartbeat 使用
      `acknowledgement=0`，可靠帧关联被拒绝的 sequence。
- [x] 将协议/controller 回归接入可调用的 CI 默认路径；完整双 Guest QEMU
      运行仍由显式脚本和已有 AArch64 QEMU 证据 job 负责。
- [ ] 在当前 HEAD 重新采集 ACK/重传、乱序/重复、Safe/恢复和 fault pcap；
      正常双向 UDP、ACK/STATUS 和基础 pcap 已由当前 HEAD YOLO 运行覆盖。

验收：Task2 从当前保守 24/25 提升到 24–25/25 的证据完整度，且失败时能
指出具体协议阶段。

## 阶段 3：Task3 模型抽象（先于 YOLO 集成）

- [x] 建立 `task3_model::perception` 的模型输出契约、YOLO tensor 解码、
      置信度/面积/坐标校验和单帧目标变化率限制。
- [x] 将 Linux controller 的模型选择显式化为 `baseline`、`cnn` 与 `yolo` 三种模式；
      `TASK3_AI=1` 仍兼容旧 CNN 构建；新构建显式选择模式。
- [x] 为模型输出定义统一的 `PerceptionDecision`/目标值边界：模型只能给出
      目标区间、置信度和来源，最终控制仍经过范围、变化率、sequence 和
      Safe 状态校验。
- [x] 保持 T2N1 CONTROL/STATUS/ACK/HEARTBEAT/ERROR 协议不变；模型替换不能
      改变可靠传输和恢复语义。
- [x] 在日志中增加模型名、模型版本/hash、推理耗时、置信度、目标值和拒绝原因。

验收：`cnn` 模式的现有结果逐字节/逐字段保持兼容；无效模型输出会被拒绝，
不会绕过 RTOS 侧安全边界。

## 阶段 4：Task3 YOLO 感知模式

### 模型选择

首选 **YOLOv8n 320**（或同等规模的 YOLO11n），理由是模型小、生态成熟、
已有仓库中的 `yolov8n_320.kmodel` K230/Starry 路径可作为后续硬件扩展参考。
QEMU/AArch64 Task3 不直接依赖 K230 专用 `.kmodel`，而使用可校验的 ONNX
或 TorchScript artifact；K230 `.kmodel` 只作为 StarryOS/NPU 补充路径。

- [x] 增加模型准备/运行脚本：下载并校验 YOLO11n ONNX artifact，记录来源、
      输入尺寸和 SHA256；缺少依赖或 hash 不匹配时显式失败。
- [x] 增加固定小型图像 fixture 和 detection→target manifest，覆盖无检测、
      正常检测和单帧目标步长限制。
- [x] 实现 YOLO 输出到控制目标的适配：目标框中心/面积经过置信度阈值、
      最大变化率和 hold-last-target 安全行为后映射到 0..1000
      的 setpoint；无目标不会产生新的越界控制跳变。
- [x] 给 Linux controller 增加 `TASK3_MODEL=yolo`、模型路径和可配置阈值参数；
      `TASK3_MODEL=cnn` 保持现有 CNN 闭环。
- [x] 增加模型日志 marker：`TASK3_MODEL_READY`、`TASK3_DETECTION`、
      `TASK3_MODEL_REJECTED`、`TASK3_CONTROL_SENT`。

验收：固定 fixture 上检测框、置信度和 setpoint 与 golden JSON 一致；YOLO
模式能通过现有 T2N1 链路驱动 Zephyr 控制任务；模型缺失、低置信度、越界和
黑障恢复均进入可观察的安全路径。

## 阶段 5：Task3 量化补充实验

- [ ] 在同一固定场景下交错运行 `cnn`、`yolo` 和 baseline，各至少 3 次。
- [ ] 统计控制 RMSE、settling time、超调、周期级 RTT、模型推理时间、
      检测置信度和拒绝次数。
- [ ] 单独报告模型推理成本，不能把 YOLO 推理耗时误报成网络延迟或 RTOS 延迟。
- [ ] 在一次 link-blackout/恢复运行中验证 YOLO 模式的 Safe→Active 行为。
- [ ] 更新 Task3 设计文档、README、summary.csv、pcap/log/hash 清单。

验收：YOLO 结果与 CNN/baseline 的比较条件、模型 hash、命令和原始数据齐全；
不把 QEMU TCG 数字表述为硬实时保证。

## 阶段 6：StarryOS、多 RTOS 与补充实验（按收益裁剪）

- [ ] 如果 StarryOS 能完成同一个可观察 Task3 闭环，再争取官网 StarryOS 替代
      Linux 的加分；单纯启动不计入完成。
- [ ] 将已有 K230 YOLOv8n/NNCase 路径作为 StarryOS/NPU 扩展证据，保持与
      QEMU/AArch64 Task3 的模型契约分离。
- [ ] 第二种 RTOS 或第二块板卡只在已有构建、镜像和运行路径稳定后进行；
      它最多争取 2 分，不得阻塞主线提交。
- [ ] Task1 补充实验只在成本低且能直接补“可比最坏情况数据”缺口时执行；
      不为追求单个漂亮 P99 重开调度机制探索。

## 阶段 7：最终审计与远程交付

- [ ] 按评分表逐项填写“证据路径、命令、结果、限制”。
- [ ] 检查所有新提交均可从远程分支重放；检查 PR head 与结果 hash 一致。
- [ ] 每个阶段的 commit message 使用 `type(scope): subject`，并推送到相应
      `origin/openrace/*` 分支。
- [ ] 最终报告明确区分：已证明、部分证明、未验证和外部阻塞项。
