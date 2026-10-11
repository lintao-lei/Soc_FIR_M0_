# FPGA 上板清单

## 1. 收集开发板信息

在写 XDC 前必须确认：

- 开发板准确型号；
- FPGA 完整器件型号和 speed grade；
- 板载晶振频率和时钟引脚；
- 复位按键引脚及有效电平；
- USB-UART 的 FPGA RX/TX 引脚和 I/O 电压；
- 可用 LED 引脚；
- 下载器类型。

不能只根据 `xc7a100tcsg324-1` 猜开发板引脚。

## 2. 完成约束

复制：

```text
constraints/board_template.xdc
```

为：

```text
constraints/board.xdc
```

填写 `clk_board`、`reset_n`、`uart_rx`、`uart_tx`、`led_run` 和 `led_error` 的 PACKAGE_PIN、IOSTANDARD，并按真实晶振创建时钟。

## 3. 核对时钟与 UART

当前 `soc_clock_reset` 默认把板级时钟直接作为系统时钟。若板载频率不适合，应加入 Clocking Wizard/MMCM。UART 的时钟周期/分频参数必须与最终系统时钟和目标波特率一致。

## 4. 固件初始化

确认代码 SRAM 在综合实现时使用最终 `.hex/.mem` 初始化，或者建立 JTAG/调试器加载方式。行为仿真中由 Testbench 使用 `$readmemh` 直接预装，不能自动等同于 FPGA 上电后的 BRAM 初始化。

## 5. 综合检查

- 无 latch、多驱动和未连接关键端口；
- SRAM 尽可能推断成 Block RAM；
- FIR 的乘加资源符合预期；
- 没有把代码/数据存储全部实现为大量寄存器；
- 综合后的时钟和复位结构正确。

## 6. 实现与时序

运行 `scripts/run_implementation.tcl`，检查：

- DRC 无阻止生成位流的错误；
- WNS ≥ 0；
- TNS = 0；
- 实现后的系统时钟频率至少达到比赛要求的 25 MHz；
- 所有顶层 I/O 都有明确的引脚和电气约束。

## 7. 分阶段上板

1. 只验证时钟、复位和 LED；
2. 验证 Cortex-M0 能从代码 SRAM 取指；
3. 运行 UART 最小发送程序；
4. 运行 UART 轮询回显；
5. 运行 SRAM 自检；
6. 运行 FIR 单位系数测试；
7. 运行六通道 DMA 综合场景；
8. 长时间循环并监视 `led_error`、UART 日志和中断计数。

每一步失败时只调试当前新增层，不要直接从“无输出”跳到整个 SoC 波形。

