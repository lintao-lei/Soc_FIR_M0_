`timescale 1ns / 1ps

// -----------------------------------------------------------------------------
// 六通道 DMA 核心
//
// 内部包含：
//   1. dma6_register_file：保存六套任务配置、状态和中断；
//   2. dma6_scheduler    ：轮询选择一个 PENDING 通道；
//   3. dma_carry        ：执行实际的 AXI INCR Burst 搬运。
//
// 寄存器侧使用简化的本地读写接口。后续由 axi_dma_reg_slave 把 CPU 的
// AXI 请求转换成 wr_en/wr_offset/wr_data/rd_offset/rd_data。
//
// dma_carry 支持源地址和目标地址分别选择递增或固定：
//   - 两侧都递增时，使用最多16拍的INCR Burst；
//   - 任意一侧固定时，使用多次单拍INCR传输。
// -----------------------------------------------------------------------------

module dma6_core (
    input  wire        clk,
    input  wire        reset_n,

    // CPU 通过 AXI 寄存器从机转换后使用的本地寄存器接口
    input  wire        wr_en,
    input  wire [11:0] wr_offset,
    input  wire [31:0] wr_data,
    input  wire [11:0] rd_offset,
    output wire [31:0] rd_data,

    // 六个 DMA 通道的状态与中断
    output wire [5:0]  channel_pending,
    output wire [5:0]  channel_busy,
    output wire [5:0]  channel_done,
    output wire [5:0]  channel_error,
    output wire [5:0]  irq,

    // AXI 主机读地址通道
    output wire [31:0] m_araddr,
    output wire [7:0]  m_arlen,
    output wire [2:0]  m_arsize,
    output wire [1:0]  m_arburst,
    output wire        m_arvalid,
    input  wire        m_arready,

    // AXI 主机读数据通道
    input  wire [31:0] m_rdata,
    input  wire [1:0]  m_rresp,
    input  wire        m_rlast,
    input  wire        m_rvalid,
    output wire        m_rready,

    // AXI 主机写地址通道
    output wire [31:0] m_awaddr,
    output wire [7:0]  m_awlen,
    output wire [2:0]  m_awsize,
    output wire [1:0]  m_awburst,
    output wire        m_awvalid,
    input  wire        m_awready,

    // AXI 主机写数据通道
    output wire [31:0] m_wdata,
    output wire [3:0]  m_wstrb,
    output wire        m_wlast,
    output wire        m_wvalid,
    input  wire        m_wready,

    // AXI 主机写响应通道
    input  wire [1:0]  m_bresp,
    input  wire        m_bvalid,
    output wire        m_bready
);

    // 寄存器文件送给调度器和搬运执行器的任务信息
    wire [2:0]  scheduler_channel;
    wire [31:0] scheduler_src_addr;
    wire [31:0] scheduler_dst_addr;
    wire [15:0] scheduler_word_count;
    wire        scheduler_irq_enable;
    wire        scheduler_src_increment;
    wire        scheduler_dst_increment;
    wire        scheduler_fixed_burst_enable;
    wire        scheduler_claim;
    wire        scheduler_complete;
    wire        scheduler_error;
    wire        scheduler_enable;

    // 调度器与单任务搬运执行器之间的控制信号
    wire engine_start;
    wire engine_busy;
    wire engine_done;
    wire engine_error;

    // -------------------------------------------------------------------------
    // 六通道配置、状态和中断寄存器文件
    // -------------------------------------------------------------------------

    dma6_register_file u_dma6_register_file (
        .clk                     (clk),
        .reset_n                 (reset_n),

        .wr_en                   (wr_en),
        .wr_offset               (wr_offset),
        .wr_data                 (wr_data),
        .rd_offset               (rd_offset),
        .rd_data                 (rd_data),

        .channel_pending         (channel_pending),
        .channel_busy            (channel_busy),
        .channel_done            (channel_done),
        .channel_error           (channel_error),

        .scheduler_channel       (scheduler_channel),
        .scheduler_src_addr      (scheduler_src_addr),
        .scheduler_dst_addr      (scheduler_dst_addr),
        .scheduler_word_count    (scheduler_word_count),
        .scheduler_irq_enable    (scheduler_irq_enable),
        .scheduler_src_increment (scheduler_src_increment),
        .scheduler_dst_increment (scheduler_dst_increment),
        .scheduler_fixed_burst_enable(scheduler_fixed_burst_enable),

        .scheduler_claim         (scheduler_claim),
        .scheduler_complete      (scheduler_complete),
        .scheduler_error         (scheduler_error),
        .scheduler_enable        (scheduler_enable),

        .irq                     (irq)
    );

    // -------------------------------------------------------------------------
    // 六通道轮询调度器
    // -------------------------------------------------------------------------

    dma6_scheduler u_dma6_scheduler (
        .clk                (clk),
        .reset_n            (reset_n),
        .scheduler_enable   (scheduler_enable),

        .channel_pending    (channel_pending),

        .scheduler_channel  (scheduler_channel),
        .scheduler_claim    (scheduler_claim),

        .engine_start       (engine_start),
        .engine_busy        (engine_busy),
        .engine_done        (engine_done),
        .engine_error       (engine_error),

        .scheduler_complete (scheduler_complete),
        .scheduler_error    (scheduler_error)
    );

    // -------------------------------------------------------------------------
    // 单任务 AXI Burst 搬运执行器
    // -------------------------------------------------------------------------

    dma_carry u_dma_engine (
        .clk        (clk),
        .reset_n    (reset_n),

        .start      (engine_start),
        .src_addr   (scheduler_src_addr),
        .dst_addr   (scheduler_dst_addr),
        .word_count (scheduler_word_count),
        .allow_fixed_burst(scheduler_fixed_burst_enable),
        .src_increment (scheduler_src_increment),
        .dst_increment (scheduler_dst_increment),
        .busy       (engine_busy),
        .done       (engine_done),
        .error      (engine_error),

        .m_araddr   (m_araddr),
        .m_arlen    (m_arlen),
        .m_arsize   (m_arsize),
        .m_arburst  (m_arburst),
        .m_arvalid  (m_arvalid),
        .m_arready  (m_arready),

        .m_rdata    (m_rdata),
        .m_rresp    (m_rresp),
        .m_rlast    (m_rlast),
        .m_rvalid   (m_rvalid),
        .m_rready   (m_rready),

        .m_awaddr   (m_awaddr),
        .m_awlen    (m_awlen),
        .m_awsize   (m_awsize),
        .m_awburst  (m_awburst),
        .m_awvalid  (m_awvalid),
        .m_awready  (m_awready),

        .m_wdata    (m_wdata),
        .m_wstrb    (m_wstrb),
        .m_wlast    (m_wlast),
        .m_wvalid   (m_wvalid),
        .m_wready   (m_wready),

        .m_bresp    (m_bresp),
        .m_bvalid   (m_bvalid),
        .m_bready   (m_bready)
    );

    // 中断使能已经由寄存器文件内部用于生成 irq，执行器本身无需使用。
    // 归约到 unused 信号，明确表示该连接是有意保留的。
    wire unused_scheduler_irq_enable = &{
        1'b0,
        scheduler_irq_enable
    };

endmodule
