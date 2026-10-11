#include "uart.h"
#include "soc_memory_map.h"

/* UART register offsets inside the 4-KiB UART address window. */
#define UART_TXDATA_OFFSET  0x000u
#define UART_RXDATA_OFFSET  0x004u
#define UART_STATUS_OFFSET  0x008u
#define UART_CTRL_OFFSET    0x00cu

/*
 * The present Cortex-M0 AHB-to-AXI bridge accepts aligned 32-bit accesses.
 * Therefore every UART register access remains 32-bit even though TX/RX data
 * uses only the low byte.
 */
static volatile uint32_t *uart_register(uint32_t offset)
{
    return (volatile uint32_t *)(uintptr_t)(SOC_UART0_BASE + offset);
}

static uint32_t uart_read_register(uint32_t offset)
{
    return *uart_register(offset);
}

static void uart_write_register(uint32_t offset, uint32_t value)
{
    *uart_register(offset) = value;
}

void uart_init(uint32_t irq_enable_mask)
{
    /* STATUS bit 2 is write-one-to-clear. */
    uart_write_register(UART_STATUS_OFFSET, UART_STATUS_FRAME_ERROR);
    uart_set_irq_enable(irq_enable_mask);
}

uint32_t uart_get_status(void)
{
    return uart_read_register(UART_STATUS_OFFSET);
}

uint32_t uart_get_control(void)
{
    return uart_read_register(UART_CTRL_OFFSET);
}

void uart_set_irq_enable(uint32_t irq_enable_mask)
{
    uart_write_register(UART_CTRL_OFFSET,
                        irq_enable_mask & UART_CTRL_IRQ_MASK);
}

void uart_clear_frame_error(void)
{
    uart_write_register(UART_STATUS_OFFSET, UART_STATUS_FRAME_ERROR);
}

int uart_tx_has_space(void)
{
    return (uart_get_status() & UART_STATUS_TX_SPACE) != 0u;
}

int uart_tx_fifo_empty(void)
{
    return (uart_get_status() & UART_STATUS_TX_FIFO_EMPTY) != 0u;
}

int uart_rx_available(void)
{
    return (uart_get_status() & UART_STATUS_RX_AVAILABLE) != 0u;
}

int uart_rx_fifo_full(void)
{
    return (uart_get_status() & UART_STATUS_RX_FIFO_FULL) != 0u;
}

int uart_frame_error_pending(void)
{
    return (uart_get_status() & UART_STATUS_FRAME_ERROR) != 0u;
}

int uart_try_putc(uint32_t value)
{
    if (!uart_tx_has_space())
        return 0;

    uart_write_register(UART_TXDATA_OFFSET, value & 0xffu);
    return 1;
}

int uart_try_getc(uint32_t *value)
{
    if (value == NULL || !uart_rx_available())
        return 0;

    *value = uart_read_register(UART_RXDATA_OFFSET) & 0xffu;
    return 1;
}

void uart_putc(uint32_t value)
{
    while (!uart_try_putc(value)) {
        /* Wait until the hardware TX FIFO has room. */
    }
}

uint32_t uart_getc(void)
{
    uint32_t value;

    while (!uart_try_getc(&value)) {
        /* Wait until the hardware RX FIFO contains a byte. */
    }
    return value;
}

int uart_putc_timeout(uint32_t value, uint32_t poll_limit)
{
    while (poll_limit != 0u) {
        if (uart_try_putc(value))
            return UART_OK;
        --poll_limit;
    }
    return UART_TIMEOUT;
}

int uart_getc_timeout(uint32_t *value, uint32_t poll_limit)
{
    if (value == NULL)
        return UART_BAD_ARG;

    while (poll_limit != 0u) {
        if (uart_try_getc(value))
            return UART_OK;
        --poll_limit;
    }
    return UART_TIMEOUT;
}

void uart_write_words(const uint32_t *data, size_t word_count)
{
    size_t index;

    if (data == NULL)
        return;

    for (index = 0u; index < word_count; ++index)
        uart_putc(data[index]);
}

void uart_write_hex32(uint32_t value)
{
    int shift;
    uint32_t nibble;

    uart_putc((uint32_t)'0');
    uart_putc((uint32_t)'x');
    for (shift = 28; shift >= 0; shift -= 4) {
        nibble = (value >> shift) & 0x0fu;
        uart_putc(nibble < 10u ?
                  ((uint32_t)'0' + nibble) :
                  ((uint32_t)'A' + nibble - 10u));
    }
}
