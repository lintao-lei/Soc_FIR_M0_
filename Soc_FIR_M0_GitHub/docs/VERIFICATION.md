# 最终比赛仿真验收报告

## 结论

2026-10-11 使用 Vivado 2019.2 XSim 对发布源码执行最终聚合回归，结果为 **11/11 PASS**。原始日志位于 `verification/results/`。

行为仿真能够证明 RTL/固件的功能和受测协议行为，但不能证明 FPGA 引脚正确、板上电气行为、布局布线后的时序或 25 MHz 实机稳定性。

## 验收项目

| 序号 | 验收内容 | 关键结果 |
|---:|---|---|
| 1 | AXI SRAM 合法单拍、4/8/16 拍和背压 | 255 checks，0 errors |
| 2 | AXI SRAM 非法请求、WLAST 错误和事务中途复位 | 207 checks，0 errors；10 个 B 响应、28 个 R beat |
| 3 | 81 抽头 FIR、随机向量、系数、FIFO 和背压 | 1847 checks；0 functional errors；最长 81 个连续 1 sample/cycle |
| 4 | APB UART TX/RX FIFO 满空行为 | 382 checks |
| 5 | Cortex-M0 C 固件轮询 UART 完整回显 | 75 checks；2635 次 MMIO 读、56 次 MMIO 写 |
| 6 | 六通道 DMA AXI 配置从机 | 290 checks，0 errors |
| 7 | DMA INCR Burst、随机背压、4 KiB 拆分和错误处理 | 1316 checks；覆盖 1/4/8/16/20 word |
| 8 | DMA 16 拍 FIXED/INCR 和 UART 单拍转换 | 367 checks |
| 9 | CPU/DMA 持续读争用公平性 | CPU 20 次、DMA 20 次授权；DMA 最大等待 5 周期 |
| 10 | CPU/DMA 持续写争用公平性 | CPU/DMA 各 20 次授权和 B 响应；DMA 最大等待 5 周期 |
| 11 | Cortex-M0 六通道 DMA/FIR/UART/SRAM/IRQ 综合场景 | 389 checks；IRQ[13:8] 全部观察到；6 次 ISR 状态读取；无 lockup |

## AXI SRAM 证明范围

- 单拍和 4/8/16 拍 INCR；
- 随机 READY 背压；
- VALID 阻塞期间地址、数据和响应保持；
- RLAST/WLAST 最后一拍位置；
- 未对齐地址；
- 非法 Burst 和非法 Size；
- `AxLEN > 15`；
- 直接跨越 4 KiB；
- WLAST 提前和最后一拍缺少 WLAST；
- 读写事务中途复位；
- 错误写事务不破坏哨兵数据。

## FIR 证明范围

- 确认为 81 抽头；
- 16 位系数与 16 位输入；
- 全零、单位系数、冲激、常数、随机输入和随机系数；
- 输出背压；
- 清空后重新运行；
- 重新装载系数；
- 持续输入达到 1 sample/cycle；
- 软件参考模型比对无功能差异；
- 复位中断 Burst 后无旧样本残留。

## UART 与系统软件证明范围

- 单字符、字符串、连续字符回显；
- RX/TX FIFO 满、空、排空和超时；
- Cortex-M0 确实通过 MMIO 驱动 UART；
- 六个 DMA 通道背靠背提交；
- PENDING、BUSY、DONE、ERROR 状态相互独立；
- IRQ[8] 到 IRQ[13] 映射和 ISR 清除行为；
- SRAM→FIR、FIR→SRAM、SRAM→UART、UART→SRAM 和两组 SRAM→SRAM；
- CPU 轮询与 DMA 总线访问共存，最终数据零差错。

## 尚需实机证明

- 目标开发板的引脚与 I/O 电压；
- 实际晶振、复位极性和 UART 波特率；
- 综合后 BRAM/DSP 推断；
- 实现后 WNS/TNS 和至少 25 MHz 时序；
- 位流配置、上电复位和长时间稳定性；
- 真实串口和外部数据交互。

