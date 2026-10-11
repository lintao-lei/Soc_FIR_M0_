#ifndef CORTEX_M0_IRQ_H
#define CORTEX_M0_IRQ_H

#include <stdint.h>

#include "soc_memory_map.h"

/* Cortex-M0 NVIC 的第一个32位外部中断寄存器组。 */
#define CORTEX_M0_NVIC_ISER0_ADDR (0xe000e100u)
#define CORTEX_M0_NVIC_ICER0_ADDR (0xe000e180u)
#define CORTEX_M0_NVIC_ISPR0_ADDR (0xe000e200u)
#define CORTEX_M0_NVIC_ICPR0_ADDR (0xe000e280u)

static inline void cortex_m0_irq_global_disable(void)
{
    __asm volatile ("cpsid i" ::: "memory");
}

static inline void cortex_m0_irq_global_enable(void)
{
    __asm volatile ("cpsie i" ::: "memory");
}

static inline void cortex_m0_nvic_enable(uint32_t irq_mask)
{
    MMIO32(CORTEX_M0_NVIC_ISER0_ADDR) = irq_mask;
}

static inline void cortex_m0_nvic_disable(uint32_t irq_mask)
{
    MMIO32(CORTEX_M0_NVIC_ICER0_ADDR) = irq_mask;
}

static inline void cortex_m0_nvic_clear_pending(uint32_t irq_mask)
{
    MMIO32(CORTEX_M0_NVIC_ICPR0_ADDR) = irq_mask;
}

#endif
