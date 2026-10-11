#include "dma.h"
#include "soc_memory_map.h"

static int dma_channel_is_valid(uint32_t channel)
{
    return channel < DMA_CHANNEL_COUNT;
}

static uintptr_t dma_register_address(uint32_t channel, uint32_t offset)
{
    return (uintptr_t)(SOC_DMA_BASE +
                       channel * DMA_CHANNEL_STRIDE +
                       offset);
}

static uint32_t dma_read_register(uint32_t channel, uint32_t offset)
{
    return MMIO32(dma_register_address(channel, offset));
}

static void dma_write_register(uint32_t channel,
                               uint32_t offset,
                               uint32_t value)
{
    MMIO32(dma_register_address(channel, offset)) = value;
}

static uintptr_t dma_global_register_address(uint32_t offset)
{
    return (uintptr_t)(SOC_DMA_BASE + offset);
}

static uint32_t dma_read_global_register(uint32_t offset)
{
    return MMIO32(dma_global_register_address(offset));
}

static void dma_write_global_register(uint32_t offset, uint32_t value)
{
    MMIO32(dma_global_register_address(offset)) = value;
}

static int dma_transfer_arguments_are_valid(uint32_t channel,
                                            uint32_t src_addr,
                                            uint32_t dst_addr,
                                            uint32_t word_count)
{
    if (!dma_channel_is_valid(channel))
        return DMA_BAD_CHANNEL;

    /* 当前硬件只支持对齐的32位word传输。 */
    if (((src_addr | dst_addr) & 3u) != 0u ||
        word_count == 0u || word_count > 0xffffu)
        return DMA_BAD_ARGUMENT;

    return DMA_OK;
}

static int dma_channel_can_be_configured(uint32_t channel)
{
    uint32_t status = dma_get_status(channel);

    if ((status & (DMA_STATUS_PENDING | DMA_STATUS_BUSY)) != 0u)
        return DMA_CHANNEL_LOCKED;
    return DMA_OK;
}

int dma_configure(uint32_t channel,
                  uint32_t src_addr,
                  uint32_t dst_addr,
                  uint32_t word_count,
                  uint32_t control_options)
{
    int result;

    result = dma_transfer_arguments_are_valid(channel,
                                              src_addr,
                                              dst_addr,
                                              word_count);
    if (result != DMA_OK)
        return result;

    result = dma_channel_can_be_configured(channel);
    if (result != DMA_OK)
        return result;

    dma_write_register(channel, DMA_REG_SRC_ADDR_OFFSET, src_addr);
    dma_write_register(channel, DMA_REG_DST_ADDR_OFFSET, dst_addr);
    dma_write_register(channel, DMA_REG_WORD_COUNT_OFFSET, word_count);
    dma_write_register(channel, DMA_REG_CONTROL_OFFSET,
                       control_options & DMA_CONTROL_OPTION_MASK);
    return DMA_OK;
}

int dma_start(uint32_t channel)
{
    uint32_t control;
    int result;

    if (!dma_channel_is_valid(channel))
        return DMA_BAD_CHANNEL;

    result = dma_channel_can_be_configured(channel);
    if (result != DMA_OK)
        return result;

    control = dma_get_control(channel) & DMA_CONTROL_OPTION_MASK;
    dma_write_register(channel, DMA_REG_CONTROL_OFFSET,
                       control | DMA_CONTROL_START);
    return DMA_OK;
}

int dma_start_transfer(uint32_t channel,
                       uint32_t src_addr,
                       uint32_t dst_addr,
                       uint32_t word_count,
                       uint32_t control_options)
{
    int result;

    result = dma_transfer_arguments_are_valid(channel,
                                              src_addr,
                                              dst_addr,
                                              word_count);
    if (result != DMA_OK)
        return result;

    result = dma_channel_can_be_configured(channel);
    if (result != DMA_OK)
        return result;

    /*
     * CONTROL最后写入，保证硬件看到START时前三项配置已经稳定。
     * 该函数总共只产生四次MMIO写。
     */
    dma_write_register(channel, DMA_REG_SRC_ADDR_OFFSET, src_addr);
    dma_write_register(channel, DMA_REG_DST_ADDR_OFFSET, dst_addr);
    dma_write_register(channel, DMA_REG_WORD_COUNT_OFFSET, word_count);
    dma_write_register(channel, DMA_REG_CONTROL_OFFSET,
                       (control_options & DMA_CONTROL_OPTION_MASK) |
                       DMA_CONTROL_START);
    return DMA_OK;
}

int dma_wait(uint32_t channel, uint32_t poll_limit)
{
    uint32_t status;

    if (!dma_channel_is_valid(channel))
        return DMA_BAD_CHANNEL;

    while (poll_limit != 0u) {
        status = dma_get_status(channel);
        if ((status & DMA_STATUS_ERROR) != 0u)
            return DMA_HARDWARE_ERROR;
        if ((status & DMA_STATUS_DONE) != 0u)
            return DMA_OK;
        --poll_limit;
    }
    return DMA_TIMEOUT;
}

void dma_scheduler_pause(void)
{
    dma_write_global_register(DMA_REG_GLOBAL_CONTROL_OFFSET, 0u);
}

void dma_scheduler_resume(void)
{
    dma_write_global_register(DMA_REG_GLOBAL_CONTROL_OFFSET,
                              DMA_GLOBAL_SCHEDULER_ENABLE);
}

int dma_scheduler_is_enabled(void)
{
    return (dma_read_global_register(DMA_REG_GLOBAL_CONTROL_OFFSET) &
            DMA_GLOBAL_SCHEDULER_ENABLE) != 0u;
}

uint32_t dma_get_pending_mask(void)
{
    return dma_read_global_register(DMA_REG_PENDING_MASK_OFFSET) &
           DMA_ALL_CHANNELS_MASK;
}

uint32_t dma_get_busy_mask(void)
{
    return dma_read_global_register(DMA_REG_BUSY_MASK_OFFSET) &
           DMA_ALL_CHANNELS_MASK;
}

uint32_t dma_get_done_mask(void)
{
    return dma_read_global_register(DMA_REG_DONE_MASK_OFFSET) &
           DMA_ALL_CHANNELS_MASK;
}

uint32_t dma_get_error_mask(void)
{
    return dma_read_global_register(DMA_REG_ERROR_MASK_OFFSET) &
           DMA_ALL_CHANNELS_MASK;
}

int dma_wait_mask(uint32_t channel_mask, uint32_t poll_limit)
{
    uint32_t requested_mask;

    requested_mask = channel_mask & DMA_ALL_CHANNELS_MASK;
    if (requested_mask == 0u || requested_mask != channel_mask)
        return DMA_BAD_ARGUMENT;

    while (poll_limit != 0u) {
        if ((dma_get_error_mask() & requested_mask) != 0u)
            return DMA_HARDWARE_ERROR;

        if ((dma_get_done_mask() & requested_mask) == requested_mask)
            return DMA_OK;

        --poll_limit;
    }

    return DMA_TIMEOUT;
}

uint32_t dma_get_control(uint32_t channel)
{
    if (!dma_channel_is_valid(channel))
        return 0u;
    return dma_read_register(channel, DMA_REG_CONTROL_OFFSET);
}

uint32_t dma_get_status(uint32_t channel)
{
    if (!dma_channel_is_valid(channel))
        return 0u;
    return dma_read_register(channel, DMA_REG_STATUS_OFFSET);
}

uint32_t dma_get_remaining(uint32_t channel)
{
    if (!dma_channel_is_valid(channel))
        return 0u;
    return dma_read_register(channel, DMA_REG_REMAINING_OFFSET);
}

uint32_t dma_get_current_src(uint32_t channel)
{
    if (!dma_channel_is_valid(channel))
        return 0u;
    return dma_read_register(channel, DMA_REG_CURRENT_SRC_OFFSET);
}

uint32_t dma_get_current_dst(uint32_t channel)
{
    if (!dma_channel_is_valid(channel))
        return 0u;
    return dma_read_register(channel, DMA_REG_CURRENT_DST_OFFSET);
}

int dma_is_pending(uint32_t channel)
{
    return (dma_get_status(channel) & DMA_STATUS_PENDING) != 0u;
}

int dma_is_busy(uint32_t channel)
{
    return (dma_get_status(channel) & DMA_STATUS_BUSY) != 0u;
}

int dma_is_done(uint32_t channel)
{
    return (dma_get_status(channel) & DMA_STATUS_DONE) != 0u;
}

int dma_has_error(uint32_t channel)
{
    return (dma_get_status(channel) & DMA_STATUS_ERROR) != 0u;
}

int dma_clear_status(uint32_t channel, uint32_t status_mask)
{
    if (!dma_channel_is_valid(channel))
        return DMA_BAD_CHANNEL;

    dma_write_register(channel, DMA_REG_STATUS_OFFSET,
                       status_mask & DMA_STATUS_W1C_MASK);
    return DMA_OK;
}

int dma_clear_done(uint32_t channel)
{
    return dma_clear_status(channel, DMA_STATUS_DONE);
}

int dma_clear_error(uint32_t channel)
{
    return dma_clear_status(channel, DMA_STATUS_ERROR);
}

int dma_clear_all_status(uint32_t channel)
{
    return dma_clear_status(channel, DMA_STATUS_W1C_MASK);
}

uint32_t dma_get_irq_number(uint32_t channel)
{
    if (!dma_channel_is_valid(channel))
        return DMA_INVALID_IRQ_NUMBER;
    return SOC_IRQ_DMA_BASE + channel;
}
