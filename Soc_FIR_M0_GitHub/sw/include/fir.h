#ifndef SOC_FIR_H
#define SOC_FIR_H

#include <stdint.h>

/* FIR 固定为 81 抽头，输入和系数使用有符号 Q15。 */
#define FIR_TAP_COUNT                 (81u)

/* FIR 控制窗口内部寄存器偏移。 */
#define FIR_REG_CTRL_OFFSET           (0x000u)
#define FIR_REG_STATUS_OFFSET         (0x004u)
#define FIR_REG_DATA_IN_OFFSET        (0x008u)
#define FIR_REG_DATA_OUT_OFFSET       (0x00cu)
#define FIR_REG_COEFF0_OFFSET         (0x010u)
#define FIR_REG_LENGTH_OFFSET         (0x158u)
#define FIR_REG_IRQ_ENABLE_OFFSET     (0x15cu)

/* CTRL：ENABLE 为保持位，LOAD/CLEAR 为写 1 触发的单周期动作。 */
#define FIR_CTRL_ENABLE               (1u << 0)
#define FIR_CTRL_LOAD                 (1u << 1)
#define FIR_CTRL_CLEAR                (1u << 2)

/* STATUS：DONE/OVERFLOW 为 sticky，并使用写 1 清除。 */
#define FIR_STATUS_BUSY               (1u << 0)
#define FIR_STATUS_DONE               (1u << 1)
#define FIR_STATUS_OVERFLOW           (1u << 2)
#define FIR_STATUS_W1C_MASK           (FIR_STATUS_DONE | \
                                       FIR_STATUS_OVERFLOW)

#define FIR_IRQ_DONE_ENABLE           (1u << 0)
#define FIR_IRQ_OVERFLOW_ENABLE       (1u << 1)
#define FIR_IRQ_ENABLE_MASK           (FIR_IRQ_DONE_ENABLE | \
                                       FIR_IRQ_OVERFLOW_ENABLE)

#define FIR_OK                         (0)
#define FIR_BAD_ARGUMENT              (-1)
#define FIR_TIMEOUT                   (-2)
#define FIR_OVERFLOW                  (-3)

/* 清空历史、结果 FIFO 和 sticky 状态，同时关闭 FIR。 */
void fir_clear(void);

/* 写一个影子系数；q15_coefficient 的合法范围为 -32768～32767。 */
int fir_write_coefficient(uint32_t index, int32_t q15_coefficient);

/* 一次写完全部 81 个影子系数。数组元素使用 32 位以适配当前 CPU 总线子集。 */
int fir_write_coefficients(const int32_t *q15_coefficients,
                           uint32_t coefficient_count);

/* 把影子系数原子装载到 FIR 活动系数，并保持 FIR 为关闭状态。 */
void fir_load_coefficients(void);

/* 帧长度范围为 1～65535 个输出样本。 */
int fir_set_length(uint32_t sample_count);

void fir_set_irq_enable(uint32_t irq_enable_mask);
void fir_enable(void);
void fir_disable(void);

uint32_t fir_get_control(void);
uint32_t fir_get_status(void);
uint32_t fir_get_last_output(void);

/* 轮询 DONE；检测到 OVERFLOW 时立即返回 FIR_OVERFLOW。 */
int fir_wait_done(uint32_t poll_limit);

/* DONE 和 OVERFLOW 为写 1 清除，其他位会被驱动屏蔽。 */
void fir_clear_status(uint32_t status_mask);

/*
 * 完成一帧开始前的标准配置：
 * CLEAR -> 写81个系数 -> LOAD -> LEN -> IRQ_EN -> ENABLE。
 */
int fir_prepare_frame(const int32_t *q15_coefficients,
                      uint32_t coefficient_count,
                      uint32_t sample_count,
                      uint32_t irq_enable_mask);

#endif
