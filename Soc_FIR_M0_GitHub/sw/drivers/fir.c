#include "fir.h"
#include "soc_memory_map.h"

static uintptr_t fir_register_address(uint32_t offset)
{
    return (uintptr_t)(SOC_FIR_CTRL_BASE + offset);
}

static uint32_t fir_read_register(uint32_t offset)
{
    return MMIO32(fir_register_address(offset));
}

static void fir_write_register(uint32_t offset, uint32_t value)
{
    MMIO32(fir_register_address(offset)) = value;
}

void fir_clear(void)
{
    /* CLEAR 写入时 bit0=0，因此清空后 FIR 保持关闭。 */
    fir_write_register(FIR_REG_CTRL_OFFSET, FIR_CTRL_CLEAR);
}

int fir_write_coefficient(uint32_t index, int32_t q15_coefficient)
{
    if (index >= FIR_TAP_COUNT ||
        q15_coefficient < -32768 || q15_coefficient > 32767)
        return FIR_BAD_ARGUMENT;

    fir_write_register(FIR_REG_COEFF0_OFFSET + index * 4u,
                       (uint32_t)q15_coefficient & 0xffffu);
    return FIR_OK;
}

int fir_write_coefficients(const int32_t *q15_coefficients,
                           uint32_t coefficient_count)
{
    uint32_t index;
    int result;

    if (q15_coefficients == (const int32_t *)0 ||
        coefficient_count != FIR_TAP_COUNT)
        return FIR_BAD_ARGUMENT;

    for (index = 0u; index < FIR_TAP_COUNT; ++index) {
        result = fir_write_coefficient(index, q15_coefficients[index]);
        if (result != FIR_OK)
            return result;
    }
    return FIR_OK;
}

void fir_load_coefficients(void)
{
    fir_write_register(FIR_REG_CTRL_OFFSET, FIR_CTRL_LOAD);
}

int fir_set_length(uint32_t sample_count)
{
    if (sample_count == 0u || sample_count > 0xffffu)
        return FIR_BAD_ARGUMENT;

    fir_write_register(FIR_REG_LENGTH_OFFSET, sample_count);
    return FIR_OK;
}

void fir_set_irq_enable(uint32_t irq_enable_mask)
{
    fir_write_register(FIR_REG_IRQ_ENABLE_OFFSET,
                       irq_enable_mask & FIR_IRQ_ENABLE_MASK);
}

void fir_enable(void)
{
    fir_write_register(FIR_REG_CTRL_OFFSET, FIR_CTRL_ENABLE);
}

void fir_disable(void)
{
    fir_write_register(FIR_REG_CTRL_OFFSET, 0u);
}

uint32_t fir_get_control(void)
{
    return fir_read_register(FIR_REG_CTRL_OFFSET);
}

uint32_t fir_get_status(void)
{
    return fir_read_register(FIR_REG_STATUS_OFFSET);
}

uint32_t fir_get_last_output(void)
{
    return fir_read_register(FIR_REG_DATA_OUT_OFFSET);
}

int fir_wait_done(uint32_t poll_limit)
{
    uint32_t status;

    while (poll_limit != 0u) {
        status = fir_get_status();
        if ((status & FIR_STATUS_OVERFLOW) != 0u)
            return FIR_OVERFLOW;
        if ((status & FIR_STATUS_DONE) != 0u)
            return FIR_OK;
        --poll_limit;
    }
    return FIR_TIMEOUT;
}

void fir_clear_status(uint32_t status_mask)
{
    fir_write_register(FIR_REG_STATUS_OFFSET,
                       status_mask & FIR_STATUS_W1C_MASK);
}

int fir_prepare_frame(const int32_t *q15_coefficients,
                      uint32_t coefficient_count,
                      uint32_t sample_count,
                      uint32_t irq_enable_mask)
{
    int result;

    if (sample_count == 0u || sample_count > 0xffffu)
        return FIR_BAD_ARGUMENT;

    fir_clear();

    result = fir_write_coefficients(q15_coefficients, coefficient_count);
    if (result != FIR_OK)
        return result;

    fir_load_coefficients();

    result = fir_set_length(sample_count);
    if (result != FIR_OK)
        return result;

    fir_set_irq_enable(irq_enable_mask);
    fir_enable();
    return FIR_OK;
}
