# SoC 裸机软件工作区

后续可持续维护的 C 代码统一放在 `sw` 目录中，不再把正式驱动写进
testbench 目录。

```text
sw/
├── include/
│   ├── soc_memory_map.h   SoC 公共地址表
│   ├── cortex_m0_irq.h    Cortex-M0全局中断和NVIC基础操作
│   ├── uart.h             UART 驱动公开接口
│   ├── dma.h              六通道 DMA 驱动公开接口
│   └── fir.h              81 抽头 FIR 驱动公开接口
├── drivers/
│   ├── uart.c             UART 寄存器和 FIFO 操作
│   ├── dma.c              六通道 DMA 配置、状态和等待操作
│   └── fir.c              FIR 系数、帧长度、状态和中断操作
├── apps/
│   ├── uart_smoke/main.c       CPU轮询UART示例
│   ├── uart_echo/main.c        UART回显示例
│   ├── dma_uart/main.c         DMA与UART双向搬运示例
│   └── dma_six_scenario/main.c 六通道FIR/UART/SRAM综合场景
└── linker/
    └── soc_cm0.ld         Cortex-M0 链接脚本
```

以后按照同一规则增加最终比赛程序：

```text
sw/apps/competition_demo/main.c
```

当前 UART 驱动提供：初始化、状态查询、阻塞/非阻塞收发、带超时收发、
32 位字符数组输出和十六进制输出。所有 MMIO 和软件缓冲区访问均使用
对齐的 32 位操作，以匹配当前 AHB-to-AXI 桥的能力。普通 `char *` 字符串
接口要等桥支持 8 位 AHB 传输后再加入，避免 Cortex-M0 产生 STRB/LDRB。

DMA 驱动支持六个通用通道、四种源/目标地址递增组合、完成/错误状态、
W1C 状态清除、轮询超时和每通道 IRQ 编号查询。它还提供调度器
`pause/resume`、六通道 `PENDING/BUSY/DONE/ERROR` 聚合掩码读取，以及
`dma_wait_mask()` 批量等待接口。当前 DMA 数据宽度固定为 32 位，源地址和
目标地址都必须 4 字节对齐，每项任务最多 65535 个 word。

要让六个通道在同一时刻都处于 PENDING，软件顺序是：先调用
`dma_scheduler_pause()`，配置并启动六个通道，确认
`dma_get_pending_mask() == DMA_ALL_CHANNELS_MASK`，最后调用
`dma_scheduler_resume()`。暂停只阻止调度器领取下一项任务，不会强行中止
已经 BUSY 的搬运。完整用法见 `sw/apps/dma_six_scenario/main.c`。

六通道综合场景已经改为中断完成方式，不再通过轮询DONE掩码判断搬运结束：

1. 向量表把外部中断8～13分别映射到DMA0～DMA5处理函数；
2. 软件先清NVIC pending，再使能NVIC的位8～13并执行`cpsie i`；
3. 每个ISR读取本通道STATUS，把DONE/ERROR记录到软件事件掩码；
4. ISR用W1C写回STATUS，撤销DMA的电平中断源；
5. 主程序等待六个软件事件位全部到达，再检查FIR/UART/SRAM结果。

链接器会从`0x2000_0000`开始放置`.data/.bss`，所以应用固定使用的邮箱、
DMA源数组和目标数组从`0x2000_1000`以后开始，不能再与链接器管理的C全局
变量共用`0x2000_0000`。对应端到端验证是
`sim/cortex_m0/tb_soc_top_cpu_dma6_scenario.sv`。

FIR 驱动支持清空、81 个 Q15 系数写入、LOAD、帧长度、使能、中断使能、
DONE/OVERFLOW 状态和轮询等待。系数数组故意使用 32 位元素，避免当前
AHB-to-AXI 桥尚未支持的 16 位 CPU 访存。端到端示例位于
`sim/cortex_m0/cpu_dma_fir_pipeline.c`，使用 DMA0 完成 SRAM→FIR，使用
DMA1 完成 FIR→SRAM，并比较 16 个 Q15 输出。
