#ifndef SOC_MEMORY_MAP_H
#define SOC_MEMORY_MAP_H

#include <stdint.h>

/* Keep synchronized with rtl/include/soc_addr_map.vh. */
#define SOC_CODE_SRAM_BASE  (0x00000000UL)
#define SOC_DATA_SRAM_BASE  (0x20000000UL)
#define SOC_FIR_CTRL_BASE   (0x40000000UL)
#define SOC_FIR_DATA_BASE   (0x40001000UL)
#define SOC_UART0_BASE      (0x40004000UL)
#define SOC_DMA_BASE        (0x4000E000UL)
#define SOC_SYSTEM_BASE     (0x4000F000UL)

#define SOC_IRQ_UART0       (0U)
#define SOC_IRQ_FIR_DONE    (1U)
#define SOC_IRQ_FIR_OVF     (2U)
#define SOC_IRQ_DMA_BASE    (8U)

#define MMIO32(address) (*(volatile uint32_t *)(uintptr_t)(address))

#endif
