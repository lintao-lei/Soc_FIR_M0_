#include <stdint.h>

#include "soc_memory_map.h"
#include "uart.h"

#define RESULT_VALUE_ADDR  (SOC_DATA_SRAM_BASE + 0x000u)
#define RESULT_STATE_ADDR  (SOC_DATA_SRAM_BASE + 0x004u)
#define PASS_SIGNATURE     0x50415353u
#define FAIL_SIGNATURE     0x4641494cu

extern uint32_t _estack;
__attribute__((naked, noreturn)) void Reset_Handler(void);

__attribute__((used, section(".isr_vector")))
const uint32_t vector_table[2] = {
    (uint32_t)&_estack,
    (uint32_t)Reset_Handler
};

__attribute__((noreturn)) int main(void)
{
    uint32_t received = 0u;

    MMIO32(RESULT_VALUE_ADDR) = 0u;
    MMIO32(RESULT_STATE_ADDR) = 0u;

    uart_init(UART_CTRL_RX_IRQ_ENABLE);
    if (uart_get_control() != UART_CTRL_RX_IRQ_ENABLE)
        goto failed;

    if (uart_putc_timeout(0x55u, 10000u) != UART_OK)
        goto failed;

    if (uart_getc_timeout(&received, 100000u) != UART_OK)
        goto failed;

    MMIO32(RESULT_VALUE_ADDR) = (uint32_t)received;
    MMIO32(RESULT_STATE_ADDR) =
        ((received & 0xffu) == 0xa5u) ? PASS_SIGNATURE : FAIL_SIGNATURE;

    for (;;) __asm volatile ("nop");

failed:
    MMIO32(RESULT_STATE_ADDR) = FAIL_SIGNATURE;
    for (;;) __asm volatile ("nop");
}

void Reset_Handler(void)
{
    __asm volatile ("b main");
}
