#include <stdint.h>

#include "dma.h"
#include "dma_uart.h"
#include "soc_memory_map.h"

/*
 * Cortex-M0端到端DMA/UART验证固件。
 * 一个32位word只携带最低8位字符，这是当前32位DMA与8位UART之间的
 * 明确软件数据格式。
 */
#define MAILBOX_BASE       0x20000000u
#define TX_BUFFER_BASE     0x20000100u
#define RX_BUFFER_BASE     0x20000200u
#define CHARACTER_COUNT    32u

#define ST_BOOT            0x00000100u
#define ST_TX_ACTIVE       0x00000110u
#define ST_TX_DONE         0x00000111u
#define ST_RX_ACTIVE       0x00000120u
#define ST_RX_DONE         0x00000121u
#define ST_ALL_DONE        0x00000130u
#define ST_FAILED          0x000001ffu

#define PASS_SIGNATURE     0x50415353u
#define FAIL_SIGNATURE     0x4641494cu

#define TX_CHANNEL         2u
#define RX_CHANNEL         3u
#define DMA_POLL_LIMIT     2000000u

extern uint32_t _estack;
__attribute__((naked, noreturn)) void Reset_Handler(void);

__attribute__((used, section(".isr_vector")))
const uint32_t vector_table[2] = {
    (uint32_t)&_estack,
    (uint32_t)Reset_Handler
};

static uint32_t tx_character(uint32_t index)
{
    return (uint32_t)(0x30u + index);
}

static uint32_t rx_character(uint32_t index)
{
    return (uint32_t)(0x80u ^ index);
}

static void mailbox_write(uint32_t offset, uint32_t value)
{
    MMIO32(MAILBOX_BASE + offset) = value;
}

__attribute__((noreturn)) int main(void)
{
    uint32_t index;
    uint32_t tx_status;
    uint32_t rx_status;
    uint32_t failure_stage = 0u;
    int result;

    mailbox_write(0u, ST_BOOT);
    mailbox_write(4u, 0u);
    mailbox_write(8u, 0u);
    mailbox_write(12u, 0u);
    mailbox_write(16u, 0u);

    for (index = 0u; index < CHARACTER_COUNT; ++index) {
        MMIO32(TX_BUFFER_BASE + 4u * index) = tx_character(index);
        MMIO32(RX_BUFFER_BASE + 4u * index) = 0xdeadbeefu;
    }

    failure_stage = 1u;
    mailbox_write(0u, ST_TX_ACTIVE);
    result = dma_uart_transmit(TX_CHANNEL,
                               (const uint32_t *)TX_BUFFER_BASE,
                               CHARACTER_COUNT,
                               0);
    if (result != DMA_OK)
        goto failed;

    failure_stage = 2u;
    if (dma_wait(TX_CHANNEL, DMA_POLL_LIMIT) != DMA_OK)
        goto failed;
    tx_status = dma_get_status(TX_CHANNEL);
    mailbox_write(12u, tx_status);
    if ((tx_status & (DMA_STATUS_PENDING | DMA_STATUS_BUSY |
                      DMA_STATUS_DONE | DMA_STATUS_ERROR)) != DMA_STATUS_DONE)
        goto failed;
    mailbox_write(0u, ST_TX_DONE);

    failure_stage = 3u;
    result = dma_uart_receive(RX_CHANNEL,
                              (uint32_t *)RX_BUFFER_BASE,
                              CHARACTER_COUNT,
                              0);
    if (result != DMA_OK)
        goto failed;
    mailbox_write(0u, ST_RX_ACTIVE);

    failure_stage = 4u;
    if (dma_wait(RX_CHANNEL, DMA_POLL_LIMIT) != DMA_OK)
        goto failed;
    rx_status = dma_get_status(RX_CHANNEL);
    mailbox_write(16u, rx_status);
    if ((rx_status & (DMA_STATUS_PENDING | DMA_STATUS_BUSY |
                      DMA_STATUS_DONE | DMA_STATUS_ERROR)) != DMA_STATUS_DONE)
        goto failed;
    mailbox_write(0u, ST_RX_DONE);

    failure_stage = 5u;
    for (index = 0u; index < CHARACTER_COUNT; ++index) {
        if (MMIO32(RX_BUFFER_BASE + 4u * index) != rx_character(index))
            goto failed;
    }

    mailbox_write(0u, ST_ALL_DONE);
    mailbox_write(4u, PASS_SIGNATURE);
    for (;;) __asm volatile ("nop");

failed:
    mailbox_write(8u, failure_stage);
    mailbox_write(0u, ST_FAILED);
    mailbox_write(4u, FAIL_SIGNATURE);
    for (;;) __asm volatile ("nop");
}

void Reset_Handler(void)
{
    __asm volatile ("b main");
}
