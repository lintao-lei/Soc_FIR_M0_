#include <stdint.h>

#include "cortex_m0_irq.h"
#include "dma.h"
#include "fir.h"
#include "soc_memory_map.h"
#include "uart.h"

/*
 * 六通道综合场景固件。
 *
 * 通道0：SRAM -> FIR
 * 通道1：FIR  -> SRAM
 * 通道2：SRAM -> UART
 * 通道3：UART -> SRAM
 * 通道4：SRAM -> SRAM
 * 通道5：SRAM -> SRAM
 *
 * 当前硬件只有一台dma_carry搬运引擎，所以“六通道同时提交”的准确含义是
 * 六个通道可以同时处于PENDING；调度器随后按0、1、2、3、4、5逐项执行。
 */

/*
 * 0x2000_0000起始区域留给链接器放置.data/.bss/栈。
 * 固定测试区从+0x1000开始，避免与C全局变量发生地址重叠。
 */
#define MAILBOX_BASE       (SOC_DATA_SRAM_BASE + 0x1000u)
#define FIR_INPUT_BASE     (SOC_DATA_SRAM_BASE + 0x1200u)
#define FIR_OUTPUT_BASE    (SOC_DATA_SRAM_BASE + 0x1400u)
#define UART_TX_BASE       (SOC_DATA_SRAM_BASE + 0x1600u)
#define UART_RX_BASE       (SOC_DATA_SRAM_BASE + 0x1700u)
#define COPY4_SRC_BASE     (SOC_DATA_SRAM_BASE + 0x1800u)
#define COPY4_DST_BASE     (SOC_DATA_SRAM_BASE + 0x1900u)
#define COPY5_SRC_BASE     (SOC_DATA_SRAM_BASE + 0x1a00u)
#define COPY5_DST_BASE     (SOC_DATA_SRAM_BASE + 0x1b00u)

#define TEST_WORDS         (16u)
#define ALL_CHANNELS       (DMA_ALL_CHANNELS_MASK)
#define HOST_POLL_LIMIT    (2000000u)
#define IRQ_WAIT_LIMIT     (200000u)
#define DMA_NVIC_MASK      (DMA_ALL_CHANNELS_MASK << SOC_IRQ_DMA_BASE)

#define ST_BOOT            (0x00000600u)
#define ST_ALL_PENDING     (0x00000610u)
#define ST_RUNNING         (0x00000620u)
#define ST_ALL_DONE        (0x00000630u)
#define ST_FAILED          (0x000006ffu)

#define PASS_SIGNATURE     (0x50415353u)
#define FAIL_SIGNATURE     (0x4641494cu)
#define HOST_READY_VALUE   (0x484f5354u) /* ASCII "HOST" */
#define GUARD_VALUE        (0xcafef00du)

/* MAILBOX中的word偏移。testbench会写HOST_READY，其余由固件写。 */
#define MB_STAGE           (0u)
#define MB_SIGNATURE       (1u)
#define MB_FAILURE         (2u)
#define MB_HOST_READY      (3u)
#define MB_PENDING_MASK    (4u)
#define MB_BUSY_MASK       (5u)
#define MB_DONE_MASK       (6u)
#define MB_ERROR_MASK      (7u)
#define MB_FIR_STATUS      (8u)
#define MB_IRQ_DONE_EVENTS (9u)
#define MB_IRQ_ERROR_EVENTS (10u)
#define MB_IRQ_COUNT0      (11u)

extern uint32_t _estack;
__attribute__((naked, noreturn)) void Reset_Handler(void);

void DMA0_IRQHandler(void);
void DMA1_IRQHandler(void);
void DMA2_IRQHandler(void);
void DMA3_IRQHandler(void);
void DMA4_IRQHandler(void);
void DMA5_IRQHandler(void);

__attribute__((used, section(".isr_vector")))
const uintptr_t vector_table[16u + SOC_IRQ_DMA_BASE + DMA_CHANNEL_COUNT] = {
    [0] = (uintptr_t)&_estack,
    [1] = (uintptr_t)Reset_Handler,
    [16u + SOC_IRQ_DMA_BASE + 0u] = (uintptr_t)DMA0_IRQHandler,
    [16u + SOC_IRQ_DMA_BASE + 1u] = (uintptr_t)DMA1_IRQHandler,
    [16u + SOC_IRQ_DMA_BASE + 2u] = (uintptr_t)DMA2_IRQHandler,
    [16u + SOC_IRQ_DMA_BASE + 3u] = (uintptr_t)DMA3_IRQHandler,
    [16u + SOC_IRQ_DMA_BASE + 4u] = (uintptr_t)DMA4_IRQHandler,
    [16u + SOC_IRQ_DMA_BASE + 5u] = (uintptr_t)DMA5_IRQHandler
};

/*
 * 这些变量由普通程序和中断服务函数共同访问，必须使用volatile。
 * 当前启动代码没有通用C运行库初始化，因此main会在开中断前显式清零。
 */
static volatile uint32_t dma_irq_done_events;
static volatile uint32_t dma_irq_error_events;
static volatile uint32_t dma_irq_count[DMA_CHANNEL_COUNT];

static void dma_channel_irq_handler(uint32_t channel)
{
    uint32_t status = dma_get_status(channel);
    uint32_t channel_bit = 1u << channel;
    uint32_t active_status = status & DMA_STATUS_W1C_MASK;

    if ((active_status & DMA_STATUS_ERROR) != 0u)
        dma_irq_error_events |= channel_bit;
    if ((active_status & DMA_STATUS_DONE) != 0u)
        dma_irq_done_events |= channel_bit;

    /*
     * 电平中断撤销与Cortex-M0退出异常之间可能存在几个周期的延迟。
     * 只有真正看到DONE/ERROR的那次进入才记为一次DMA完成事件。
     */
    if (active_status != 0u)
        ++dma_irq_count[channel];

    /* DONE/ERROR是电平型sticky中断源；不W1C清除会立刻再次进入ISR。 */
    if (active_status != 0u)
        dma_clear_status(channel, active_status);

    /* 清除源之后再清NVIC中可能残留的pending状态。 */
    cortex_m0_nvic_clear_pending(channel_bit << SOC_IRQ_DMA_BASE);
}

void DMA0_IRQHandler(void) { dma_channel_irq_handler(0u); }
void DMA1_IRQHandler(void) { dma_channel_irq_handler(1u); }
void DMA2_IRQHandler(void) { dma_channel_irq_handler(2u); }
void DMA3_IRQHandler(void) { dma_channel_irq_handler(3u); }
void DMA4_IRQHandler(void) { dma_channel_irq_handler(4u); }
void DMA5_IRQHandler(void) { dma_channel_irq_handler(5u); }

static const int32_t unit_coefficients[FIR_TAP_COUNT] = {
    32767
};

static void mailbox_write(uint32_t word_offset, uint32_t value)
{
    MMIO32(MAILBOX_BASE + word_offset * 4u) = value;
}

static uint32_t mailbox_read(uint32_t word_offset)
{
    return MMIO32(MAILBOX_BASE + word_offset * 4u);
}

static int32_t fir_input_sample(uint32_t index)
{
    return (int32_t)(index * 257u) - 1928;
}

static int32_t fir_expected_sample(int32_t sample)
{
    int32_t product = sample * 32767;
    int32_t magnitude;

    if (product < 0) {
        magnitude = -product;
        return -((magnitude + 16384) >> 15);
    }
    return (product + 16384) >> 15;
}

static uint32_t uart_tx_value(uint32_t index)
{
    return 0x40u + index;
}

static uint32_t uart_rx_value(uint32_t index)
{
    return 0xa0u + index;
}

static int configure_all_channels(void)
{
    int result;

    result = dma_configure(0u, FIR_INPUT_BASE, SOC_FIR_DATA_BASE,
                           TEST_WORDS,
                           DMA_MODE_MEMORY_TO_DEVICE |
                           DMA_CONTROL_FIXED_BURST_ENABLE |
                           DMA_CONTROL_IRQ_ENABLE);
    if (result != DMA_OK)
        return result;

    result = dma_configure(1u, SOC_FIR_DATA_BASE, FIR_OUTPUT_BASE,
                           TEST_WORDS,
                           DMA_MODE_DEVICE_TO_MEMORY |
                           DMA_CONTROL_FIXED_BURST_ENABLE |
                           DMA_CONTROL_IRQ_ENABLE);
    if (result != DMA_OK)
        return result;

    /* UART固定地址侧必须拆成单拍，因此这里不设置FIXED_BURST_ENABLE。 */
    result = dma_configure(2u, UART_TX_BASE, UART_DMA_TXDATA_ADDR,
                           TEST_WORDS,
                           DMA_MODE_MEMORY_TO_DEVICE |
                           DMA_CONTROL_IRQ_ENABLE);
    if (result != DMA_OK)
        return result;

    result = dma_configure(3u, UART_DMA_RXDATA_ADDR, UART_RX_BASE,
                           TEST_WORDS,
                           DMA_MODE_DEVICE_TO_MEMORY |
                           DMA_CONTROL_IRQ_ENABLE);
    if (result != DMA_OK)
        return result;

    result = dma_configure(4u, COPY4_SRC_BASE, COPY4_DST_BASE,
                           TEST_WORDS,
                           DMA_MODE_MEMORY_TO_MEMORY |
                           DMA_CONTROL_IRQ_ENABLE);
    if (result != DMA_OK)
        return result;

    return dma_configure(5u, COPY5_SRC_BASE, COPY5_DST_BASE,
                         TEST_WORDS,
                         DMA_MODE_MEMORY_TO_MEMORY |
                         DMA_CONTROL_IRQ_ENABLE);
}

static int start_all_channels(void)
{
    uint32_t channel;
    int result;

    for (channel = 0u; channel < DMA_CHANNEL_COUNT; ++channel) {
        result = dma_start(channel);
        if (result != DMA_OK)
            return result;
    }
    return DMA_OK;
}

__attribute__((noreturn)) int main(void)
{
    uint32_t index;
    uint32_t channel;
    uint32_t host_wait;
    uint32_t failure_stage = 0u;
    uint32_t pending_mask;
    uint32_t busy_mask;
    uint32_t done_mask;
    uint32_t error_mask;
    uint32_t fir_status;
    uint32_t irq_wait;
    int32_t sample;
    int result;

    for (index = 0u; index < MB_IRQ_COUNT0 + DMA_CHANNEL_COUNT; ++index)
        mailbox_write(index, 0u);
    mailbox_write(MB_STAGE, ST_BOOT);

    dma_irq_done_events = 0u;
    dma_irq_error_events = 0u;
    for (channel = 0u; channel < DMA_CHANNEL_COUNT; ++channel)
        dma_irq_count[channel] = 0u;

    /* 先关闭并清空NVIC，完成全部软件状态初始化后再允许DMA中断。 */
    cortex_m0_irq_global_disable();
    cortex_m0_nvic_disable(DMA_NVIC_MASK);
    cortex_m0_nvic_clear_pending(DMA_NVIC_MASK);

    for (index = 0u; index < TEST_WORDS; ++index) {
        sample = fir_input_sample(index);
        MMIO32(FIR_INPUT_BASE + index * 4u) = (uint32_t)sample & 0xffffu;
        MMIO32(FIR_OUTPUT_BASE + index * 4u) = 0xdeadbeefu;

        MMIO32(UART_TX_BASE + index * 4u) = uart_tx_value(index);
        MMIO32(UART_RX_BASE + index * 4u) = 0xdeadbeefu;

        MMIO32(COPY4_SRC_BASE + index * 4u) = 0x44000000u + index;
        MMIO32(COPY4_DST_BASE + index * 4u) = 0xdeadbeefu;
        MMIO32(COPY5_SRC_BASE + index * 4u) = 0x55000000u + index;
        MMIO32(COPY5_DST_BASE + index * 4u) = 0xdeadbeefu;
    }
    MMIO32(FIR_OUTPUT_BASE + TEST_WORDS * 4u) = GUARD_VALUE;
    MMIO32(UART_RX_BASE + TEST_WORDS * 4u) = GUARD_VALUE;
    MMIO32(COPY4_DST_BASE + TEST_WORDS * 4u) = GUARD_VALUE;
    MMIO32(COPY5_DST_BASE + TEST_WORDS * 4u) = GUARD_VALUE;

    failure_stage = 1u;
    for (channel = 0u; channel < DMA_CHANNEL_COUNT; ++channel) {
        if (dma_clear_all_status(channel) != DMA_OK)
            goto failed;
    }

    failure_stage = 2u;
    result = fir_prepare_frame(unit_coefficients, FIR_TAP_COUNT,
                               TEST_WORDS, FIR_IRQ_DONE_ENABLE);
    if (result != FIR_OK)
        goto failed;

    /* 先关调度，再提交六项任务，才能稳定观察到PENDING=6'b111111。 */
    failure_stage = 3u;
    dma_scheduler_pause();
    if (dma_scheduler_is_enabled())
        goto failed;

    failure_stage = 4u;
    if (configure_all_channels() != DMA_OK)
        goto failed;

    failure_stage = 5u;
    if (start_all_channels() != DMA_OK)
        goto failed;

    pending_mask = dma_get_pending_mask();
    busy_mask = dma_get_busy_mask();
    error_mask = dma_get_error_mask();
    mailbox_write(MB_PENDING_MASK, pending_mask);
    mailbox_write(MB_BUSY_MASK, busy_mask);
    mailbox_write(MB_ERROR_MASK, error_mask);

    failure_stage = 6u;
    if (pending_mask != ALL_CHANNELS || busy_mask != 0u || error_mask != 0u)
        goto failed;

    /*
     * 仿真主机在此期间把16个字符送进UART RX FIFO，随后写HOST_READY。
     * 在板上使用时，这个握手可替换为你的真实应用条件。
     */
    mailbox_write(MB_STAGE, ST_ALL_PENDING);
    host_wait = HOST_POLL_LIMIT;
    while (mailbox_read(MB_HOST_READY) != HOST_READY_VALUE &&
           host_wait != 0u)
        --host_wait;
    failure_stage = 7u;
    if (host_wait == 0u)
        goto failed;

    mailbox_write(MB_STAGE, ST_RUNNING);

    /* 每个DMA通道已在CONTROL中设置IRQ_ENABLE，现在打开NVIC[8:13]。 */
    cortex_m0_nvic_clear_pending(DMA_NVIC_MASK);
    cortex_m0_nvic_enable(DMA_NVIC_MASK);
    cortex_m0_irq_global_enable();

    dma_scheduler_resume();
    if (!dma_scheduler_is_enabled())
        goto failed;

    failure_stage = 8u;
    irq_wait = IRQ_WAIT_LIMIT;
    while (((dma_irq_done_events | dma_irq_error_events) != ALL_CHANNELS) &&
           irq_wait != 0u) {
        /*
         * 完成条件只由ISR写入，不再轮询DMA STATUS/DONE_MASK。
         * 这里保留NOP忙等待，避免最小启动环境中WFI检查与入睡之间的竞态。
         */
        __asm volatile ("nop");
        --irq_wait;
    }
    if (irq_wait == 0u || dma_irq_error_events != 0u ||
        dma_irq_done_events != ALL_CHANNELS)
        goto failed;

    cortex_m0_irq_global_disable();
    cortex_m0_nvic_disable(DMA_NVIC_MASK);

    pending_mask = dma_get_pending_mask();
    busy_mask = dma_get_busy_mask();
    done_mask = dma_get_done_mask();
    error_mask = dma_get_error_mask();
    fir_status = fir_get_status();
    mailbox_write(MB_PENDING_MASK, pending_mask);
    mailbox_write(MB_BUSY_MASK, busy_mask);
    mailbox_write(MB_DONE_MASK, done_mask);
    mailbox_write(MB_ERROR_MASK, error_mask);
    mailbox_write(MB_FIR_STATUS, fir_status);
    mailbox_write(MB_IRQ_DONE_EVENTS, dma_irq_done_events);
    mailbox_write(MB_IRQ_ERROR_EVENTS, dma_irq_error_events);
    for (channel = 0u; channel < DMA_CHANNEL_COUNT; ++channel)
        mailbox_write(MB_IRQ_COUNT0 + channel, dma_irq_count[channel]);

    failure_stage = 9u;
    if (pending_mask != 0u || busy_mask != 0u ||
        done_mask != 0u || error_mask != 0u ||
        (fir_status & (FIR_STATUS_BUSY | FIR_STATUS_DONE |
                       FIR_STATUS_OVERFLOW)) != FIR_STATUS_DONE)
        goto failed;

    failure_stage = 10u;
    for (index = 0u; index < TEST_WORDS; ++index) {
        sample = fir_input_sample(index);
        if (MMIO32(FIR_OUTPUT_BASE + index * 4u) !=
                (uint32_t)fir_expected_sample(sample) ||
            MMIO32(UART_RX_BASE + index * 4u) != uart_rx_value(index) ||
            MMIO32(COPY4_DST_BASE + index * 4u) != 0x44000000u + index ||
            MMIO32(COPY5_DST_BASE + index * 4u) != 0x55000000u + index)
            goto failed;
    }

    failure_stage = 11u;
    if (MMIO32(FIR_OUTPUT_BASE + TEST_WORDS * 4u) != GUARD_VALUE ||
        MMIO32(UART_RX_BASE + TEST_WORDS * 4u) != GUARD_VALUE ||
        MMIO32(COPY4_DST_BASE + TEST_WORDS * 4u) != GUARD_VALUE ||
        MMIO32(COPY5_DST_BASE + TEST_WORDS * 4u) != GUARD_VALUE)
        goto failed;

    mailbox_write(MB_STAGE, ST_ALL_DONE);
    mailbox_write(MB_SIGNATURE, PASS_SIGNATURE);
    for (;;) __asm volatile ("nop");

failed:
    /* 出错路径也恢复调度开关，避免调试时把“暂停”误判为总线死锁。 */
    cortex_m0_irq_global_disable();
    cortex_m0_nvic_disable(DMA_NVIC_MASK);
    dma_scheduler_resume();
    mailbox_write(MB_FAILURE, failure_stage);
    mailbox_write(MB_STAGE, ST_FAILED);
    mailbox_write(MB_SIGNATURE, FAIL_SIGNATURE);
    for (;;) __asm volatile ("nop");
}

void Reset_Handler(void)
{
    __asm volatile ("b main");
}
