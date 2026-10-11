#ifndef SOC_DMA_H
#define SOC_DMA_H

#include <stdint.h>

/* 硬件实现了六个独立配置通道，每个通道占用0x40字节寄存器空间。 */
#define DMA_CHANNEL_COUNT          (6u)
#define DMA_CHANNEL_STRIDE         (0x40u)

/* 每个通道内部的寄存器偏移。 */
#define DMA_REG_SRC_ADDR_OFFSET    (0x00u)
#define DMA_REG_DST_ADDR_OFFSET    (0x04u)
#define DMA_REG_WORD_COUNT_OFFSET  (0x08u)
#define DMA_REG_CONTROL_OFFSET     (0x0cu)
#define DMA_REG_STATUS_OFFSET      (0x10u)
#define DMA_REG_REMAINING_OFFSET   (0x14u)
#define DMA_REG_CURRENT_SRC_OFFSET (0x18u)
#define DMA_REG_CURRENT_DST_OFFSET (0x1cu)

/*
 * DMA全局寄存器。它们不属于某个通道，因此不要再叠加通道号和0x40步长。
 * GLOBAL_CONTROL[0]只控制“是否允许调度新任务”：
 *   0：暂停选择新的PENDING通道；已经BUSY的任务继续执行到结束。
 *   1：允许调度器继续选择任务。
 */
#define DMA_REG_GLOBAL_CONTROL_OFFSET (0x180u)
#define DMA_REG_PENDING_MASK_OFFSET   (0x184u)
#define DMA_REG_BUSY_MASK_OFFSET      (0x188u)
#define DMA_REG_DONE_MASK_OFFSET      (0x18cu)
#define DMA_REG_ERROR_MASK_OFFSET     (0x190u)

#define DMA_GLOBAL_SCHEDULER_ENABLE   (1u << 0)
#define DMA_GLOBAL_CONTROL_MASK       (DMA_GLOBAL_SCHEDULER_ENABLE)
#define DMA_ALL_CHANNELS_MASK         ((1u << DMA_CHANNEL_COUNT) - 1u)

/* CONTROL寄存器位。START由启动函数自动添加。 */
#define DMA_CONTROL_START          (1u << 0)
#define DMA_CONTROL_IRQ_ENABLE     (1u << 1)
#define DMA_CONTROL_SRC_INCREMENT  (1u << 2)
#define DMA_CONTROL_DST_INCREMENT  (1u << 3)
#define DMA_CONTROL_FIXED_BURST_ENABLE (1u << 4)
#define DMA_CONTROL_OPTION_MASK    (DMA_CONTROL_IRQ_ENABLE | \
                                    DMA_CONTROL_SRC_INCREMENT | \
                                    DMA_CONTROL_DST_INCREMENT | \
                                    DMA_CONTROL_FIXED_BURST_ENABLE)

/*
 * 常用地址模式。可再与DMA_CONTROL_IRQ_ENABLE按位或。
 * 当任意一侧地址固定时，默认仍退化为多次单拍INCR，以兼容UART/APB。
 * 只有确认固定端口支持AXI FIXED Burst（例如FIR数据FIFO）时，才额外设置
 * DMA_CONTROL_FIXED_BURST_ENABLE。
 */
#define DMA_MODE_FIXED_TO_FIXED    (0u)
#define DMA_MODE_MEMORY_TO_DEVICE  (DMA_CONTROL_SRC_INCREMENT)
#define DMA_MODE_DEVICE_TO_MEMORY  (DMA_CONTROL_DST_INCREMENT)
#define DMA_MODE_MEMORY_TO_MEMORY  (DMA_CONTROL_SRC_INCREMENT | \
                                    DMA_CONTROL_DST_INCREMENT)

/* STATUS寄存器位。DONE和ERROR使用写1清除。 */
#define DMA_STATUS_PENDING         (1u << 0)
#define DMA_STATUS_BUSY            (1u << 1)
#define DMA_STATUS_DONE            (1u << 2)
#define DMA_STATUS_ERROR           (1u << 3)
#define DMA_STATUS_W1C_MASK        (DMA_STATUS_DONE | DMA_STATUS_ERROR)

/* 驱动返回值。 */
#define DMA_OK                     (0)
#define DMA_BAD_CHANNEL            (-1)
#define DMA_BAD_ARGUMENT           (-2)
#define DMA_CHANNEL_LOCKED         (-3)
#define DMA_TIMEOUT                (-4)
#define DMA_HARDWARE_ERROR         (-5)

/* 无效通道没有NVIC中断号。 */
#define DMA_INVALID_IRQ_NUMBER     (0xffffffffu)

/*
 * 只写配置，不启动任务。
 * control_options可使用IRQ_ENABLE、SRC_INCREMENT、DST_INCREMENT和
 * FIXED_BURST_ENABLE。
 */
int dma_configure(uint32_t channel,
                  uint32_t src_addr,
                  uint32_t dst_addr,
                  uint32_t word_count,
                  uint32_t control_options);

/* 启动一个已经配置好的通道。 */
int dma_start(uint32_t channel);

/* 用四次寄存器写完成“配置并启动”，适合普通一次性任务。 */
int dma_start_transfer(uint32_t channel,
                       uint32_t src_addr,
                       uint32_t dst_addr,
                       uint32_t word_count,
                       uint32_t control_options);

/* 轮询到完成、硬件错误或超时。成功后DONE仍保留，需软件显式清除。 */
int dma_wait(uint32_t channel, uint32_t poll_limit);

/*
 * 六通道批量提交辅助接口。
 * 典型用法：暂停调度器 -> 依次启动六个通道 -> 检查PENDING掩码 -> 恢复。
 * 暂停不取消PENDING，也不会中止已经BUSY的任务。
 */
void dma_scheduler_pause(void);
void dma_scheduler_resume(void);
int dma_scheduler_is_enabled(void);

uint32_t dma_get_pending_mask(void);
uint32_t dma_get_busy_mask(void);
uint32_t dma_get_done_mask(void);
uint32_t dma_get_error_mask(void);

/*
 * 等待channel_mask指定的全部通道结束。
 * 任一目标通道出现ERROR立即返回DMA_HARDWARE_ERROR；超时返回DMA_TIMEOUT。
 */
int dma_wait_mask(uint32_t channel_mask, uint32_t poll_limit);

uint32_t dma_get_control(uint32_t channel);
uint32_t dma_get_status(uint32_t channel);
uint32_t dma_get_remaining(uint32_t channel);
uint32_t dma_get_current_src(uint32_t channel);
uint32_t dma_get_current_dst(uint32_t channel);

int dma_is_pending(uint32_t channel);
int dma_is_busy(uint32_t channel);
int dma_is_done(uint32_t channel);
int dma_has_error(uint32_t channel);

/* STATUS的DONE和ERROR为W1C；传入其他位会被驱动屏蔽。 */
int dma_clear_status(uint32_t channel, uint32_t status_mask);
int dma_clear_done(uint32_t channel);
int dma_clear_error(uint32_t channel);
int dma_clear_all_status(uint32_t channel);

/* 返回SOC_IRQ_DMA_BASE + channel；非法通道返回DMA_INVALID_IRQ_NUMBER。 */
uint32_t dma_get_irq_number(uint32_t channel);

#endif
