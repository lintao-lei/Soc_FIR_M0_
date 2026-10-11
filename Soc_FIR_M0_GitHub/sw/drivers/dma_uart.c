#include "dma_uart.h"

#include <stdint.h>

#include "dma.h"
#include "uart.h"

int dma_uart_transmit(uint32_t channel,
                      const uint32_t *source,
                      uint32_t character_count,
                      int irq_enable)
{
    uint32_t options = DMA_MODE_MEMORY_TO_DEVICE;

    if (source == (const uint32_t *)0)
        return DMA_BAD_ARGUMENT;
    if (irq_enable)
        options |= DMA_CONTROL_IRQ_ENABLE;

    /*
     * 不设置FIXED_BURST_ENABLE：SRAM侧使用INCR Burst，UART侧由DMA
     * 自动拆成AWLEN=0、WLAST=1的重复单拍写事务。
     */
    return dma_start_transfer(channel,
                              (uint32_t)(uintptr_t)source,
                              UART_DMA_TXDATA_ADDR,
                              character_count,
                              options);
}

int dma_uart_receive(uint32_t channel,
                     uint32_t *destination,
                     uint32_t character_count,
                     int irq_enable)
{
    uint32_t options = DMA_MODE_DEVICE_TO_MEMORY;

    if (destination == (uint32_t *)0)
        return DMA_BAD_ARGUMENT;
    if (irq_enable)
        options |= DMA_CONTROL_IRQ_ENABLE;

    /*
     * UART侧每次只在rx_dma_req有效时读取一个word；收集最多16个word后，
     * DMA再向SRAM发一笔INCR Burst写。
     */
    return dma_start_transfer(channel,
                              UART_DMA_RXDATA_ADDR,
                              (uint32_t)(uintptr_t)destination,
                              character_count,
                              options);
}
