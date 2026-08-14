# RT 分区资源分配表（T0.4，T4.1 文档素材）

> 拓扑：QEMU virt, gic-version=3, `-smp 4`，见
> `scripts/test/rt-partition/qemu-aarch64-rt.toml`。

## 物理 CPU 分配

| pCPU | 归属 | 说明 |
|---|---|---|
| 0 | hypervisor（axvisor）+ shell + virtio-net 后台 + 注入器/housekeeping | 唯一处理 host 周期活动的核 |
| 1 | Zephyr guest vCPU0（独占） | RT 分区核，T1.1 后无 tick |
| 2 | Linux guest vCPU0 | 测量任务核（cyclictest/stress-ng） |
| 3 | Linux guest vCPU1 | 隔离核（`isolcpus=1 nohz_full=1 irqaffinity=0`） |

## 内存分配

| 区间（GPA） | 归属 | 备注 |
|---|---|---|
| 0x8000_0000 .. 0xA000_0000（512MiB） | Linux guest | MAP_ALLOC |
| 0xA000_0000 .. 0xC000_0000（512MiB） | Zephyr guest | MAP_ALLOC，二进制链接于基址 |
| host 其余 | hypervisor | rootfs/nvme 等 |

## 设备与中断

| 设备 | 中断 | 路由目标 | 说明 |
|---|---|---|---|
| virtio-net 双端口 | SPI 48（wire） | pCPU 0 | host 虚拟设备，后台任务在核 0 |
| guest UART（pl011@9000000） | SPI 33 | 独占核各自 vCPU | guest 视图 |
| 虚拟定时器（CNTV） | PPI 27 | 各自 vCPU | Zephyr 直通/模拟按配置 |
| GICv3 直通 | — | 见 vGIC 配置 | vCPU affinity = 虚拟编号，物理路由 = placement |

## Guest 内核启动参数（Linux）

```
root=/dev/nvme0n1 rw init=/init isolcpus=1 nohz_full=1 irqaffinity=0
```
- `isolcpus=1`：guest CPU1 移出内核调度器
- `nohz_full=1`：guest CPU1 关闭 tick
- `irqaffinity=0`：内核中断亲和收敛到 guest CPU0
- 通过 vm toml `[kernel] cmdline`（aarch64 FDT `patch_chosen` 路径）注入

## 双层隔离叙事

1. hypervisor 层：Zephyr 独占 pCPU1（无 host 竞争），Linux 独占 pCPU2/3
2. guest 层：Linux 内部再隔出 CPU1 跑测量任务（无内核 tick/中断竞争）
