# StarryOS Task2/Task3 bonus-path evidence

日期：2026-08-21  
分支：`openrace/starryos-task2-task3`  
工作区：`/home/huhu/tgoskits-starry`  
HEAD：`e886b65a3f3e85a5cf79e92a13cc4cc9990d8f2d`

## 结论

**状态：partial**

本次完成了当前 HEAD 上的真实双 Guest 正常路径：

```text
StarryOS Guest (10.0.42.15)
    └─ UDP/IPv4 T2N1 CONTROL
       → Zephyr Guest (10.0.42.2)
       ← T2N1 ACK + STATUS
```

StarryOS Guest 内加载静态 CNN 权重并完成真实前向推理，输出 `417`，随后通过
T2N1 CONTROL 发送给 Zephyr；Zephyr 返回 ACK/STATUS，端点打印
`STARRY_T2N1_PASS`。数据通道是 UDP/IP，没有使用共享内存、HyperCall 或裸
MMIO 替代协议。

## 已通过的验收

- AArch64 StarryOS、AxVisor、Zephyr 镜像构建成功。
- 最终运行日志包含：`TASK2_READY`、`TASK3_MODEL_READY`、`TASK3_INFER`、
  `TASK3_DETECTION`、`STARRY_T2N1_CONTROL_SENT`、`STARRY_T2N1_ACK`、
  `STARRY_T2N1_STATUS_DELIVERED`、`STARRY_T2N1_PASS`。
- 双端 pcap 通过：

  ```bash
  python3 scripts/test/net-dual-guest/verify_pcap.py \
    --tag '' --require-task2 \
    results/starryos-task2-task3-20260821-dual/final.vm1.pcap \
    results/starryos-task2-task3-20260821-dual/final.vm2.pcap
  ```

  结果：两端各 `28` 帧、`16` 个 T2N1 帧，包含 CONTROL/ACK/STATUS。
- 回归通过：

  ```bash
  cargo test -p task2-net-protocol
  cargo test -p task3-model
  python3 -m unittest discover -s scripts/test/net-dual-guest -p 'test_*.py'
  ```

  分别为 `21`、`11`、`15` 个测试通过。

## 证据文件

- 运行日志：[run-final-evidence3.log](run-final-evidence3.log)
- 构建日志：[build-final-evidence3.log](build-final-evidence3.log)
- StarryOS 侧 pcap：[final.vm1.pcap](final.vm1.pcap)
- Zephyr 侧 pcap：[final.vm2.pcap](final.vm2.pcap)
- 哈希清单：[SHA256SUMS.txt](SHA256SUMS.txt)
- 捕获步骤：[steps-final-evidence.txt](steps-final-evidence.txt)

## 限制与未完成项

1. 为使当前 AxVisor/AArch64 NVMe rootfs 稳定启动，最终证据使用
   `msix_qsize=1`，Guest 走 legacy INTx；原始 `msix_qsize=65` MSI-X passthrough
   路径仍会在 StarryOS block controller 初始化时失败。这是设备/IRQ 资源路径
   限制，不是 T2N1 协议或 CNN 推理限制。
2. 本证据覆盖正常闭环；StarryOS 专属的 ACK-drop、乱序、invalid-parameter、
   blackout→Safe→recovery 组合尚未形成同等双端 pcap 证据。协议库单元测试和
   主线 Python 故障回归已通过，但不能替代这些 StarryOS 专属运行证据。
3. 本路径复用了纯 Rust `components/task3-model` CNN；没有声称 ncnn/YOLO 在
   StarryOS Guest 内完成。YOLO 主线工作区 `/home/huhu/tgoskits-rt` 未修改。

因此当前结果按交接规定标为 `partial`，不伪造为完整 Task3 替代闭环。
