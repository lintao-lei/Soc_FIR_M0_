# 系统架构说明

## 总体数据通路

Cortex-M0 通过 AHB-Lite 发起取指和数据访问。`ahb_to_axi_bridge` 保存 AHB 地址阶段信息，并将 CPU 访问转换为单拍 AXI。DMA 是第二个 AXI 主机。`arbiter` 分别在读通道和写通道上对 CPU、DMA 进行轮询仲裁，并在一笔事务结束前锁定事务所有者，防止 Burst 中途切换主机。

仲裁后的 AXI 请求进入 `axi_interconnect_shell`，由地址译码选择代码 SRAM、数据 SRAM、FIR 控制/数据接口、DMA 寄存器或 UART 子系统。请求与响应相隔多个周期，因此互联会保存写、读事务的目标，未映射地址返回 DECERR，而不是永久等待。

## AXI 子集

- 32 位地址和 32 位数据；
- 4 字节对齐，`AxSIZE=3'b010`；
- 单拍和 INCR Burst；
- 每个 Burst 最多 16 拍；
- 一次只处理一笔读和一笔写事务，不使用 AXI ID；
- 支持 VALID/READY 背压；
- 检查 4 KiB 边界、Burst 类型、长度、对齐和 WLAST；
- 从机错误使用 SLVERR，地址译码错误使用 DECERR。

## 存储系统

代码 SRAM 和数据 SRAM 各 64 KiB，均通过 `axi_burst_sram` 接入。写通道按 WSTRB 更新字节，读通道在背压时保持 RDATA/RRESP/RLAST 稳定。非法写请求被排空后返回错误，但不修改原数据。

## FIR

FIR 包含 81 个可配置 16 位系数和 16 位输入数据。控制窗口用于清空、装载系数、使能和读取状态；数据窗口表现为 FIFO 端口：向固定地址写入一个 word 会送入一个样本，从固定地址读取一个 word 会取出一个结果。

计算核在持续输入时达到 1 sample/cycle。结果 FIFO 满时产生背压，不能覆盖旧结果；AXI R 通道被阻塞时输出保持稳定。完成和溢出状态可映射到中断。

## UART

UART 位于 APB 外设侧，由 `axi_to_apb_bridge` 转换 CPU/DMA 的 AXI 单拍访问。TX 和 RX 都带 FIFO。CPU 可轮询 TX 空间和 RX 数据；DMA 可依据 TX/RX 请求信号访问固定 TXDATA/RXDATA 地址。

## 六通道 DMA

六个通道拥有独立的源地址、目标地址、长度、递增模式、控制位、DONE/ERROR 状态和 IRQ。六通道共享一台 `dma_carry` AXI 搬运引擎，因此可以同时 PENDING，但由调度器依次执行，不是六台引擎真正并行传输。

支持场景：

- 通道 0：SRAM → FIR；
- 通道 1：FIR → SRAM；
- 通道 2：SRAM → UART；
- 通道 3：UART → SRAM；
- 通道 4：SRAM → SRAM；
- 通道 5：第二组 SRAM → SRAM / 压力任务。

SRAM 侧可使用最多 16 拍 INCR Burst。FIR 固定数据窗口可使用 FIXED Burst。当前 AXI-to-APB 只接收单拍，因此 UART 固定地址侧由 DMA 拆分成多次单拍，避免把 16 拍 AXI Burst 原样送入 APB。

## 中断

- UART：低位中断；
- FIR DONE/OVF：低位中断；
- DMA 六通道：`IRQ[8]` 到 `IRQ[13]`。

DMA DONE/ERROR 为粘滞状态，软件中断服务函数读取状态、记录事件、通过 W1C 清除通道状态，再清除 NVIC pending。

