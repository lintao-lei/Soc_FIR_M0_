#include <stdint.h>

#include "soc_memory_map.h"
#include "uart.h"

/*
 * UART 完整回显系统测试。
 *
 * Cortex-M0 只使用轮询，不使用 DMA，也不进入中断服务程序。测试固件通过
 * 数据 SRAM 中的“阶段邮箱”与 testbench 配合；testbench 只负责从串口线
 * 发送字节和接收回显，不会绕过 CPU 直接访问 UART 寄存器。
 */

#define RESULT_STAGE_ADDR       (SOC_DATA_SRAM_BASE + 0x000u)
#define RESULT_SIGNATURE_ADDR   (SOC_DATA_SRAM_BASE + 0x004u)
#define RESULT_ERROR_ADDR       (SOC_DATA_SRAM_BASE + 0x008u)
#define RESULT_RX_COUNT_ADDR    (SOC_DATA_SRAM_BASE + 0x00cu)
#define RESULT_TX_COUNT_ADDR    (SOC_DATA_SRAM_BASE + 0x010u)
#define RESULT_TX_FILL_ADDR     (SOC_DATA_SRAM_BASE + 0x014u)
#define RESULT_LAST_STATUS_ADDR (SOC_DATA_SRAM_BASE + 0x018u)

#define PASS_SIGNATURE  0x50415353u
#define FAIL_SIGNATURE  0x4641494cu

#define ST_BOOT              0x00000001u
#define ST_RX_TIMEOUT_DONE   0x00000010u
#define ST_WAIT_SINGLE       0x00000020u
#define ST_SINGLE_DONE       0x00000021u
#define ST_WAIT_STRING       0x00000030u
#define ST_STRING_DONE       0x00000031u
#define ST_WAIT_CONTINUOUS   0x00000040u
#define ST_CONTINUOUS_DONE   0x00000041u
#define ST_WAIT_RX_FULL      0x00000050u
#define ST_RX_FULL_SEEN      0x00000051u
#define ST_RX_DRAIN_DONE     0x00000052u
#define ST_TX_FILLING        0x00000060u
#define ST_TX_FULL_SEEN      0x00000061u
#define ST_TX_TIMEOUT_DONE   0x00000062u
#define ST_TX_EMPTY_SEEN     0x00000063u
#define ST_ALL_DONE          0x00000070u
#define ST_FAILED            0x000000ffu

#define STRING_BYTE_COUNT      13u
#define CONTINUOUS_BYTE_COUNT   8u
#define RX_FIFO_BYTE_COUNT     16u

/* 足够覆盖一帧 UART 的轮询次数，同时仍有明确的失败出口。 */
#define UART_LONG_POLL_LIMIT  1000000u

extern uint32_t _estack;
__attribute__((naked, noreturn)) void Reset_Handler(void);

__attribute__((used, section(".isr_vector")))
const uint32_t vector_table[2] = {
    (uint32_t)&_estack,
    (uint32_t)Reset_Handler
};

static void set_stage(uint32_t stage)
{
    MMIO32(RESULT_STAGE_ADDR) = stage;
}

static void save_counters(uint32_t rx_count, uint32_t tx_count)
{
    MMIO32(RESULT_RX_COUNT_ADDR) = rx_count;
    MMIO32(RESULT_TX_COUNT_ADDR) = tx_count;
    MMIO32(RESULT_LAST_STATUS_ADDR) = uart_get_status();
}

__attribute__((noreturn))
static void fail_test(uint32_t error_code,
                      uint32_t rx_count,
                      uint32_t tx_count)
{
    save_counters(rx_count, tx_count);
    MMIO32(RESULT_ERROR_ADDR) = error_code;
    MMIO32(RESULT_SIGNATURE_ADDR) = FAIL_SIGNATURE;
    set_stage(ST_FAILED);
    for (;;) {
        __asm volatile ("nop");
    }
}

/*
 * 从 RX FIFO 取一个字节，再把同一个字节送入 TX FIFO。
 * 只有 RXDATA 和 TXDATA 两次操作都成功后才更新计数器。
 */
static int echo_one(uint32_t *rx_count, uint32_t *tx_count)
{
    uint32_t value;

    if (uart_getc_timeout(&value, UART_LONG_POLL_LIMIT) != UART_OK)
        return 1;
    *rx_count = *rx_count + 1u;

    if (uart_putc_timeout(value, UART_LONG_POLL_LIMIT) != UART_OK)
        return 2;
    *tx_count = *tx_count + 1u;
    return 0;
}

static int echo_many(uint32_t byte_count,
                     uint32_t *rx_count,
                     uint32_t *tx_count)
{
    uint32_t index;
    int result;

    for (index = 0u; index < byte_count; ++index) {
        result = echo_one(rx_count, tx_count);
        if (result != 0)
            return result;
    }
    return 0;
}

__attribute__((noreturn)) int main(void)
{
    uint32_t rx_count = 0u;
    uint32_t tx_count = 0u;
    uint32_t tx_fill_count = 0u;
    uint32_t timeout;
    uint32_t unexpected_value = 0u;
    int result;

    MMIO32(RESULT_STAGE_ADDR) = ST_BOOT;
    MMIO32(RESULT_SIGNATURE_ADDR) = 0u;
    MMIO32(RESULT_ERROR_ADDR) = 0u;
    MMIO32(RESULT_RX_COUNT_ADDR) = 0u;
    MMIO32(RESULT_TX_COUNT_ADDR) = 0u;
    MMIO32(RESULT_TX_FILL_ADDR) = 0u;
    MMIO32(RESULT_LAST_STATUS_ADDR) = 0u;

    /* 本阶段只验证轮询；中断源保持关闭。 */
    uart_init(0u);
    if (uart_get_control() != 0u)
        fail_test(0x01u, rx_count, tx_count);
    if (uart_frame_error_pending())
        fail_test(0x02u, rx_count, tx_count);

    /* 没有输入时，软件必须能超时返回，不能永久卡在轮询中。 */
    if (uart_getc_timeout(&unexpected_value, 32u) != UART_TIMEOUT)
        fail_test(0x03u, rx_count, tx_count);
    set_stage(ST_RX_TIMEOUT_DONE);

    /* 单字符回显。 */
    set_stage(ST_WAIT_SINGLE);
    result = echo_many(1u, &rx_count, &tx_count);
    if (result != 0)
        fail_test(0x10u + (uint32_t)result, rx_count, tx_count);
    set_stage(ST_SINGLE_DONE);

    /* 字符串回显。 */
    set_stage(ST_WAIT_STRING);
    result = echo_many(STRING_BYTE_COUNT, &rx_count, &tx_count);
    if (result != 0)
        fail_test(0x20u + (uint32_t)result, rx_count, tx_count);
    set_stage(ST_STRING_DONE);

    /* 没有额外空闲位的连续字符回显。 */
    set_stage(ST_WAIT_CONTINUOUS);
    result = echo_many(CONTINUOUS_BYTE_COUNT, &rx_count, &tx_count);
    if (result != 0)
        fail_test(0x30u + (uint32_t)result, rx_count, tx_count);
    set_stage(ST_CONTINUOUS_DONE);

    /*
     * 此处故意只读 STATUS、不读 RXDATA。testbench 连续发送 16 个字节，
     * 直到硬件 RX FIFO 的 FULL 位出现，再一次性读出并回显全部内容。
     */
    set_stage(ST_WAIT_RX_FULL);
    timeout = UART_LONG_POLL_LIMIT;
    while (!uart_rx_fifo_full() && timeout != 0u)
        --timeout;
    if (timeout == 0u)
        fail_test(0x40u, rx_count, tx_count);
    set_stage(ST_RX_FULL_SEEN);

    result = echo_many(RX_FIFO_BYTE_COUNT, &rx_count, &tx_count);
    if (result != 0)
        fail_test(0x41u + (uint32_t)result, rx_count, tx_count);
    if (uart_rx_available())
        fail_test(0x44u, rx_count, tx_count);
    set_stage(ST_RX_DRAIN_DONE);

    /*
     * 先等前面的回显数据离开 TX FIFO，再高速填充 TX FIFO。最后一帧可能
     * 仍在移位器中，因此这里可成功排入 16 或 17 个新字节。
     */
    timeout = UART_LONG_POLL_LIMIT;
    while (!uart_tx_fifo_empty() && timeout != 0u)
        --timeout;
    if (timeout == 0u)
        fail_test(0x50u, rx_count, tx_count);

    set_stage(ST_TX_FILLING);
    while (tx_fill_count < 18u &&
           uart_try_putc(0xc0u + tx_fill_count)) {
        ++tx_fill_count;
        ++tx_count;
    }
    MMIO32(RESULT_TX_FILL_ADDR) = tx_fill_count;
    if (tx_fill_count < 16u || tx_fill_count > 17u)
        fail_test(0x51u, rx_count, tx_count);
    if (uart_tx_has_space())
        fail_test(0x52u, rx_count, tx_count);
    set_stage(ST_TX_FULL_SEEN);

    /* 满时 try_putc 不访问 TXDATA，所以软件超时仍然能够向前运行。 */
    if (uart_putc_timeout(0xeeu, 4u) != UART_TIMEOUT)
        fail_test(0x53u, rx_count, tx_count);
    set_stage(ST_TX_TIMEOUT_DONE);

    timeout = UART_LONG_POLL_LIMIT;
    while (!uart_tx_fifo_empty() && timeout != 0u)
        --timeout;
    if (timeout == 0u || !uart_tx_has_space())
        fail_test(0x54u, rx_count, tx_count);
    set_stage(ST_TX_EMPTY_SEEN);

    save_counters(rx_count, tx_count);
    MMIO32(RESULT_ERROR_ADDR) = 0u;
    MMIO32(RESULT_SIGNATURE_ADDR) = PASS_SIGNATURE;
    set_stage(ST_ALL_DONE);

    for (;;) {
        __asm volatile ("nop");
    }
}

void Reset_Handler(void)
{
    __asm volatile ("b main");
}
