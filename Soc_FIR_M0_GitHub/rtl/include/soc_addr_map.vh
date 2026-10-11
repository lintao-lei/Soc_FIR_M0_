`ifndef SOC_ADDR_MAP_VH
`define SOC_ADDR_MAP_VH
//soc总线上各个部分的地址
// Keep this file synchronized with sw/include/soc_memory_map.h.
// Address windows are intentionally coarse while the project is a framework.
`define SOC_CODE_SRAM_BASE 32'h0000_0000
`define SOC_CODE_SRAM_MASK 32'hFFFF_0000

`define SOC_DATA_SRAM_BASE 32'h2000_0000
`define SOC_DATA_SRAM_MASK 32'hFFFF_0000

`define SOC_FIR_CTRL_BASE  32'h4000_0000
`define SOC_FIR_CTRL_MASK  32'hFFFF_F000

`define SOC_FIR_DATA_BASE  32'h4000_1000
`define SOC_FIR_DATA_MASK  32'hFFFF_F000

`define SOC_UART0_BASE     32'h4000_4000
`define SOC_UART0_MASK     32'hFFFF_F000

`define SOC_DMA_BASE       32'h4000_E000
`define SOC_DMA_MASK       32'hFFFF_F000

`define SOC_SYSTEM_BASE    32'h4000_F000
`define SOC_SYSTEM_MASK    32'hFFFF_F000

`define SOC_IRQ_UART0      0
`define SOC_IRQ_FIR_DONE   1
`define SOC_IRQ_FIR_OVF    2
`define SOC_IRQ_DMA_BASE   8

`endif
