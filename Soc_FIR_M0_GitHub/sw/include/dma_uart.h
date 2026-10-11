#ifndef SOC_DMA_UART_H
#define SOC_DMA_UART_H

#include <stdint.h>

/*
 * 使用现有六通道DMA执行UART传输。
 * 第一版每个uint32_t只携带最低8位字符；character_count也是word数量。
 */
int dma_uart_transmit(uint32_t channel,
                      const uint32_t *source,
                      uint32_t character_count,
                      int irq_enable);

int dma_uart_receive(uint32_t channel,
                     uint32_t *destination,
                     uint32_t character_count,
                     int irq_enable);

#endif
