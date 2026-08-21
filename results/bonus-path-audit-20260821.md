# StarryOS / STERRORS / 多 RTOS 加分路径审计（2026-08-21）

本文只记录当前工作区能够复核的证据，不把“有配置”“能编译”或“理论上
支持”当成已完成的 OpenRace 加分闭环。

## 1. 审计结论

| 路径 | 当前状态 | 可提交的结论 | 缺口/阻塞 |
|---|---|---|---|
| StarryOS 替代 Linux 完成 Task3 | 未完成 | 当前正式 Task3 闭环仍是 Linux → T2N1 → Zephyr；没有 StarryOS 作为 Linux 替代 Guest 的 CONTROL/STATUS 双向证据 | 没有 StarryOS Task3 Guest 镜像、双 Guest pcap、完整 marker 链和当前 HEAD 运行目录 |
| StarryOS syscall / STERRORS 改造合入 `dev` | 未完成/未识别 | `origin/dev` 有大量一般 StarryOS syscall 修复，但没有能对应本任务 Task3 闭环或名为 STERRORS 的当前分支提交和验收证据 | 需要明确的 syscall 目标、Linux 差分 case、合入 PR 和 `STARRY_GROUPED_TESTS_PASSED` 证据；现阶段不宣称加分 |
| K230 / SG2002 YOLO 扩展 | 有代码路径，未形成当前交付证据 | `apps/starry/aka00-tennis-yolo/` 已提交固定模型/图片/expected，`apps/starry/k230-kpu-nncase/` 已提交 NPU demo 源码 | 当前环境缺 `target/qemu-k230-docker-build`、K230 SDK 和 KPU guest binary；没有本次提交可定位的运行日志/manifest |
| 第二 RTOS / 第二块板卡对比 | 未完成 | 外部历史目录有 `freertos-qemu.elf`，证明曾有 FreeRTOS benchmark guest | ELF 只包含 benchmark/启动代码，没有 T2N1/virtio-net/CONTROL/STATUS；当前 HEAD 没有可复现的 FreeRTOS 或 RT-Thread 双向闭环和对比数据 |

## 2. 已核对的正面证据

仓库包含以下可复用路径：

- `apps/starry/aka00-tennis-yolo/`：SG2002/CV181x 固定图片 YOLO 用户态 TPU
  校验器，成功 marker 为 `AKARS_TENNIS_VALIDATE_PASS`；文档中的性能表来自
  板端 Linux，不是本次 Task3 的 StarryOS 替代 Guest 闭环。
- `apps/starry/k230-kpu-nncase/`：StarryOS K230 QEMU/NNCase 应用，设计了
  `YOLOV8N_DEMO_PASS` 和 `K230_NNCASE_RUNTIME_PASS`；运行依赖 K230 QEMU
  fork、SDK、模型和 guest binary。
- `apps/starry/aka00-tennis-yolo/model/yolov8n_tennis_v2.cvimodel` 和三张
  固定图片已在仓库中，适合后续 SG2002 Linux/TPU 校验；它不是 StarryOS
  替代 Linux 的 Task3 Guest。
- `/home/huhu/tgoskits-realtime/tmp/initramfs-custom-root/guest/freertos/`
  中存在历史 `freertos-qemu.elf/bin`，`strings` 只能看到 benchmark、UART、
  FreeRTOS scheduler 和 FDT 初始化符号，没有 `TASK2_*`、UDP 或 T2N1 marker；
  因此不能作为第二 RTOS 加分证据（ELF SHA-256：
  `66c96869aa708a424951de7de3707c58caf5c1dd53d8f1e134278c564ef9dfad`）。
- `os/axvisor/configs/vms/*/freertos-smp1.toml` 和
  `phytiumpi/rtthread-smp1.toml`：VM 配置存在，但配置存在不等于当前
  Task2/Task3 网络协议和控制闭环已复现。

## 3. 当前环境的可验证阻塞

```text
target/qemu-k230-docker-build/qemu-system-riscv64 : absent
target/official-k230/                         : absent
apps/starry/k230-kpu-nncase/c/assets/bin/     : only .gitignore, no guest demo
FreeRTOS T2N1 guest / RT-Thread image         : absent
```

因此不能安全地运行 K230 路径，也不能生成真实的 StarryOS/NPU 运行 manifest。
这属于外部工具链/硬件资产缺失，不通过伪造日志或把 README 的预期 marker 当作
结果来解决。

## 4. 后续可执行条件

若后续获得 K230 QEMU fork、SDK、模型和 guest binary，应至少保存：

1. 构建日志及所有输入 artifact SHA256；
2. `YOLOV8N_DEMO_PASS`、模型输出 hash、推理耗时和失败 marker；
3. 若要计入 StarryOS 加分，还要接入同一 T2N1 CONTROL/STATUS 协议，保存
   Linux/Starry/RTOS 三端日志和双向 pcap；
4. 若要计入第二 RTOS 加分，还要在当前 HEAD 复现正常、ACK-drop/乱序或恢复
   至少一种故障场景，并给出与 Zephyr 相同指标的对比表。

本轮还检查了可用的历史 FreeRTOS ELF 和已提交的 SG2002 模型资产。前者缺少
网络协议代码，后者缺少 StarryOS/TPU 运行环境；两者都不能降低上述验收门槛。

在这些证据出现前，评分表中的 StarryOS、STERRORS 和多 RTOS 加分保持为 0，
但主线 Task2/Task3 的 Linux–Zephyr 证据不受影响。
