#ifndef SOC_UART_H
#define SOC_UART_H

#include <stddef.h>
#include <stdint.h>

#include "soc_memory_map.h"

/* CPU和DMA共同使用的32位对齐UART数据端口。 */
#define UART_TXDATA_ADDR       (SOC_UART0_BASE + 0x000u)
#define UART_RXDATA_ADDR       (SOC_UART0_BASE + 0x004u)
#define UART_STATUS_ADDR       (SOC_UART0_BASE + 0x008u)
#define UART_CTRL_ADDR         (SOC_UART0_BASE + 0x00cu)

/*
 * 当前DMA按32位word搬运，但UART只使用最低8位。因此第一版DMA UART
 * 缓冲区使用“一个uint32_t保存一个字符”的格式。
 */
#define UART_DMA_TXDATA_ADDR   UART_TXDATA_ADDR
#define UART_DMA_RXDATA_ADDR   UART_RXDATA_ADDR

/* Public STATUS register bits. */
#define UART_STATUS_TX_SPACE       (1u << 0)
#define UART_STATUS_RX_AVAILABLE   (1u << 1)
#define UART_STATUS_FRAME_ERROR    (1u << 2)
#define UART_STATUS_TX_FIFO_EMPTY  (1u << 3)
#define UART_STATUS_RX_FIFO_FULL   (1u << 4)

/* Public CTRL register bits. */
#define UART_CTRL_RX_IRQ_ENABLE    (1u << 0)
#define UART_CTRL_ERR_IRQ_ENABLE   (1u << 1)
#define UART_CTRL_IRQ_MASK         (UART_CTRL_RX_IRQ_ENABLE | \
                                    UART_CTRL_ERR_IRQ_ENABLE)

/* Return values used by the timeout functions. */
#define UART_OK          0
#define UART_TIMEOUT    -1
#define UART_BAD_ARG    -2

/* Initialize the UART and select which UART interrupt sources are enabled. */
void uart_init(uint32_t irq_enable_mask);

uint32_t uart_get_status(void);
uint32_t uart_get_control(void);
void uart_set_irq_enable(uint32_t irq_enable_mask);
void uart_clear_frame_error(void);

int uart_tx_has_space(void);
int uart_tx_fifo_empty(void);
int uart_rx_available(void);
int uart_rx_fifo_full(void);
int uart_frame_error_pending(void);

/* Non-blocking operations: return 1 on success and 0 if they would block. */
int uart_try_putc(uint32_t value);
int uart_try_getc(uint32_t *value);

/* Blocking operations. Use timeout variants in code that must recover. */
void uart_putc(uint32_t value);
uint32_t uart_getc(void);
int uart_putc_timeout(uint32_t value, uint32_t poll_limit);
int uart_getc_timeout(uint32_t *value, uint32_t poll_limit);

/*
 * Until the AHB-to-AXI bridge supports byte transfers, character buffers are
 * represented as one 32-bit word per character. Example:
 *   static const uint32_t text[] = {'O', 'K', '\r', '\n'};
 */
void uart_write_words(const uint32_t *data, size_t word_count);
void uart_write_hex32(uint32_t value);

#endif
