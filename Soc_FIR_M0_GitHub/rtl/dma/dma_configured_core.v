`timescale 1ns/1ps

// Phase-4 teaching wrapper: register control + existing burst DMA master.
// wr_en/wr_offset/wr_data/rd_offset are a local register interface for now;
// a later AXI slave adapter can drive them from CPU MMIO transactions.
module dma_configured_core (
    input wire clk,
    input wire reset_n,
    input wire wr_en,
    input wire [11:0] wr_offset,
    input wire [31:0] wr_data,
    input wire [11:0] rd_offset,
    output wire [31:0] rd_data,
    output wire busy,
    output wire done,
    output wire error,

    output wire [31:0] m_araddr,
    output wire [7:0] m_arlen,
    output wire [2:0] m_arsize,
    output wire [1:0] m_arburst,
    output wire m_arvalid,
    input wire m_arready,
    input wire [31:0] m_rdata,
    input wire [1:0] m_rresp,
    input wire m_rlast,
    input wire m_rvalid,
    output wire m_rready,

    output wire [31:0] m_awaddr,
    output wire [7:0] m_awlen,
    output wire [2:0] m_awsize,
    output wire [1:0] m_awburst,
    output wire m_awvalid,
    input wire m_awready,
    output wire [31:0] m_wdata,
    output wire [3:0] m_wstrb,
    output wire m_wlast,
    output wire m_wvalid,
    input wire m_wready,
    input wire [1:0] m_bresp,
    input wire m_bvalid,
    output wire m_bready
);
    wire [31:0] cfg_src_addr;
    wire [31:0] cfg_dst_addr;
    wire [15:0] cfg_word_count;
    wire cfg_start;

    dma_register_config u_register_config (
        .clk(clk), .reset_n(reset_n),
        .wr_en(wr_en), .wr_offset(wr_offset), .wr_data(wr_data),
        .rd_offset(rd_offset), .rd_data(rd_data),
        .src_addr(cfg_src_addr), .dst_addr(cfg_dst_addr),
        .word_count(cfg_word_count), .start(cfg_start),
        .dma_busy(busy), .dma_done(done), .dma_error(error)
    );

    dma_carry u_dma (
        .clk(clk), .reset_n(reset_n),
        .start(cfg_start), .src_addr(cfg_src_addr),
        .dst_addr(cfg_dst_addr), .word_count(cfg_word_count),
        // 旧的单通道教学封装没有地址模式配置，保持原来的内存到内存行为。
        .allow_fixed_burst(1'b0),
        .src_increment(1'b1), .dst_increment(1'b1),
        .busy(busy), .done(done), .error(error),
        .m_araddr(m_araddr), .m_arlen(m_arlen),
        .m_arsize(m_arsize), .m_arburst(m_arburst),
        .m_arvalid(m_arvalid), .m_arready(m_arready),
        .m_rdata(m_rdata), .m_rresp(m_rresp),
        .m_rlast(m_rlast), .m_rvalid(m_rvalid),
        .m_rready(m_rready),
        .m_awaddr(m_awaddr), .m_awlen(m_awlen),
        .m_awsize(m_awsize), .m_awburst(m_awburst),
        .m_awvalid(m_awvalid), .m_awready(m_awready),
        .m_wdata(m_wdata), .m_wstrb(m_wstrb),
        .m_wlast(m_wlast), .m_wvalid(m_wvalid),
        .m_wready(m_wready),
        .m_bresp(m_bresp), .m_bvalid(m_bvalid),
        .m_bready(m_bready)
    );
endmodule
