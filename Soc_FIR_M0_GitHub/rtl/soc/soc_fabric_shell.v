`timescale 1ns/1ps
`include "soc_addr_map.vh"

module soc_fabric_shell (
    input  wire        clk,
    input  wire        reset_n,

    input  wire [31:0] haddr,
    input  wire [ 2:0] hburst,
    input  wire        hmastlock,
    input  wire [ 3:0] hprot,
    input  wire [ 2:0] hsize,
    input  wire [ 1:0] htrans,
    input  wire [31:0] hwdata,
    input  wire        hwrite,
    output wire [31:0] hrdata,
    output wire        hready,
    output wire        hresp,

    input  wire        uart_rx,
    output wire        uart_tx,
    output wire [31:0] irq,
    output wire        fabric_error
);

    // CPU AXI master signals. This framework uses one outstanding transaction
    // and a constant implicit AXI ID. Add explicit IDs when the DMA/crossbar is
    // expanded to allow multiple outstanding transactions.
    wire [31:0] m_awaddr;
    wire [ 7:0] m_awlen;
    wire [ 2:0] m_awsize;
    wire [ 1:0] m_awburst;
    wire        m_awvalid;
    wire        m_awready;
    wire [31:0] m_wdata;
    wire [ 3:0] m_wstrb;
    wire        m_wlast;
    wire        m_wvalid;
    wire        m_wready;
    wire [ 1:0] m_bresp;
    wire        m_bvalid;
    wire        m_bready;
    wire [31:0] m_araddr;
    wire [ 7:0] m_arlen;
    wire [ 2:0] m_arsize;
    wire [ 1:0] m_arburst;
    wire        m_arvalid;
    wire        m_arready;
    wire [31:0] m_rdata;
    wire [ 1:0] m_rresp;
    wire        m_rlast;
    wire        m_rvalid;
    wire        m_rready;
    // AXI signals between the one-outstanding arbiter and address decoder.
    wire [31:0] a_awaddr;
    wire [ 7:0] a_awlen;
    wire [ 2:0] a_awsize;
    wire [ 1:0] a_awburst;
    wire        a_awvalid, a_awready;
    wire [31:0] a_wdata;
    wire [ 3:0] a_wstrb;
    wire        a_wlast, a_wvalid, a_wready;
    wire [ 1:0] a_bresp;
    wire        a_bvalid, a_bready;
    wire [31:0] a_araddr;
    wire [ 7:0] a_arlen;
    wire [ 2:0] a_arsize;
    wire [ 1:0] a_arburst;
    wire        a_arvalid, a_arready;
    wire [31:0] a_rdata;
    wire [ 1:0] a_rresp;
    wire        a_rlast, a_rvalid, a_rready;
    wire        fir_irq_done;
    wire        fir_irq_ovf;
    wire        uart_irq;
    wire        uart_rx_dma_req;
    wire        uart_tx_dma_req;

    // DMA register interface and second AXI master.
    wire        dma_cfg_wr_en;
    wire [11:0] dma_cfg_wr_offset, dma_cfg_rd_offset;
    wire [31:0] dma_cfg_wr_data, dma_cfg_rd_data;
    wire [5:0]  dma_pending;
    wire [5:0]  dma_busy;
    wire [5:0]  dma_done;
    wire [5:0]  dma_error;
    wire [5:0]  dma_irq;
    wire [31:0] d_awaddr, d_wdata, d_araddr, d_rdata;
    wire [ 7:0] d_awlen, d_arlen;
    wire [ 2:0] d_awsize, d_arsize;
    wire [ 1:0] d_awburst, d_arburst, d_bresp, d_rresp;
    wire [ 3:0] d_wstrb;
    wire d_awvalid_raw, d_awready_raw;
    wire d_awvalid, d_awready, d_wlast, d_wvalid, d_wready;
    wire d_bvalid, d_bready, d_arvalid, d_arready;
    wire d_arvalid_raw, d_arready_raw;
    wire d_rlast, d_rvalid, d_rready;

    ahb_to_axi_bridge u_ahb_to_axi (
        .clk        (clk),
        .reset_n    (reset_n),
        .haddr      (haddr),
        .hburst     (hburst),
        .hmastlock  (hmastlock),
        .hprot      (hprot),
        .hsize      (hsize),
        .htrans     (htrans),
        .hwdata     (hwdata),
        .hwrite     (hwrite),
        .hrdata     (hrdata),
        .hready     (hready),
        .hresp      (hresp),
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
        .m_bready   (m_bready),
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
        .m_rready   (m_rready)
    );

    // Six independently configured channels share one AXI burst engine.
    // The local register interface comes from the DMA MMIO slave inside the
    // address decoder; the AXI master side competes with the CPU below.
    dma6_core u_dma (
        .clk(clk), .reset_n(reset_n),
        .wr_en(dma_cfg_wr_en), .wr_offset(dma_cfg_wr_offset),
        .wr_data(dma_cfg_wr_data), .rd_offset(dma_cfg_rd_offset),
        .rd_data(dma_cfg_rd_data),
        .channel_pending(dma_pending),
        .channel_busy(dma_busy),
        .channel_done(dma_done),
        .channel_error(dma_error),
        .irq(dma_irq),
        .m_awaddr(d_awaddr), .m_awlen(d_awlen),
        .m_awsize(d_awsize), .m_awburst(d_awburst),
        .m_awvalid(d_awvalid_raw), .m_awready(d_awready_raw),
        .m_wdata(d_wdata), .m_wstrb(d_wstrb),
        .m_wlast(d_wlast), .m_wvalid(d_wvalid),
        .m_wready(d_wready),
        .m_bresp(d_bresp), .m_bvalid(d_bvalid), .m_bready(d_bready),
        .m_araddr(d_araddr), .m_arlen(d_arlen),
        .m_arsize(d_arsize), .m_arburst(d_arburst),
        .m_arvalid(d_arvalid_raw), .m_arready(d_arready_raw),
        .m_rdata(d_rdata), .m_rresp(d_rresp),
        .m_rlast(d_rlast), .m_rvalid(d_rvalid), .m_rready(d_rready)
    );

    // ---------------------------------------------------------------------
    // UART DMA节拍许可
    //
    // UART是单拍APB外设。DMA读RXDATA前必须确认RX FIFO非空；DMA写
    // TXDATA前必须确认TX FIFO有空间。未满足条件时不把AXI地址请求送入
    // 仲裁器，因此CPU仍可使用总线，不会被一个空等的APB事务长期占住。
    //
    // permit寄存器解决一个关键AXI规则：请求一旦已经向下游呈现VALID，
    // 即使UART请求信号随后变化，也必须保持VALID和地址直到READY握手。
    // ---------------------------------------------------------------------
    wire dma_ar_targets_uart_rx =
        (d_araddr == (`SOC_UART0_BASE + 32'h0000_0004));
    wire dma_aw_targets_uart_tx =
        (d_awaddr == (`SOC_UART0_BASE + 32'h0000_0000));
    wire dma_ar_request_now =
        !dma_ar_targets_uart_rx || uart_rx_dma_req;
    wire dma_aw_request_now =
        !dma_aw_targets_uart_tx || uart_tx_dma_req;

    reg dma_ar_permit;
    reg dma_aw_permit;
    wire dma_ar_issue_open = dma_ar_permit || dma_ar_request_now;
    wire dma_aw_issue_open = dma_aw_permit || dma_aw_request_now;

    assign d_arvalid = d_arvalid_raw && dma_ar_issue_open;
    assign d_arready_raw = d_arready && dma_ar_issue_open;
    assign d_awvalid = d_awvalid_raw && dma_aw_issue_open;
    assign d_awready_raw = d_awready && dma_aw_issue_open;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            dma_ar_permit <= 1'b0;
            dma_aw_permit <= 1'b0;
        end else begin
            if (d_arvalid && d_arready)
                dma_ar_permit <= 1'b0;
            else if (!dma_ar_permit && d_arvalid_raw &&
                     dma_ar_request_now)
                dma_ar_permit <= 1'b1;

            if (d_awvalid && d_awready)
                dma_aw_permit <= 1'b0;
            else if (!dma_aw_permit && d_awvalid_raw &&
                     dma_aw_request_now)
                dma_aw_permit <= 1'b1;
        end
    end

    arbiter u_axi_arbiter (
        .clk(clk), .reset_n(reset_n),
        .cpu_awaddr(m_awaddr), .cpu_awlen(m_awlen),
        .cpu_awsize(m_awsize), .cpu_awburst(m_awburst),
        .cpu_awvalid(m_awvalid), .cpu_awready(m_awready),
        .cpu_wdata(m_wdata), .cpu_wstrb(m_wstrb),
        .cpu_wlast(m_wlast), .cpu_wvalid(m_wvalid),
        .cpu_wready(m_wready),
        .cpu_bresp(m_bresp), .cpu_bvalid(m_bvalid),
        .cpu_bready(m_bready),
        .cpu_araddr(m_araddr), .cpu_arlen(m_arlen),
        .cpu_arsize(m_arsize), .cpu_arburst(m_arburst),
        .cpu_arvalid(m_arvalid), .cpu_arready(m_arready),
        .cpu_rdata(m_rdata), .cpu_rresp(m_rresp),
        .cpu_rlast(m_rlast), .cpu_rvalid(m_rvalid),
        .cpu_rready(m_rready),
        .dma_awaddr(d_awaddr), .dma_awlen(d_awlen),
        .dma_awsize(d_awsize), .dma_awburst(d_awburst),
        .dma_awvalid(d_awvalid), .dma_awready(d_awready),
        .dma_wdata(d_wdata), .dma_wstrb(d_wstrb),
        .dma_wlast(d_wlast), .dma_wvalid(d_wvalid),
        .dma_wready(d_wready),
        .dma_bresp(d_bresp), .dma_bvalid(d_bvalid), .dma_bready(d_bready),
        .dma_araddr(d_araddr), .dma_arlen(d_arlen),
        .dma_arsize(d_arsize), .dma_arburst(d_arburst),
        .dma_arvalid(d_arvalid), .dma_arready(d_arready),
        .dma_rdata(d_rdata), .dma_rresp(d_rresp),
        .dma_rlast(d_rlast), .dma_rvalid(d_rvalid), .dma_rready(d_rready),
        .m_awaddr(a_awaddr), .m_awlen(a_awlen),
        .m_awsize(a_awsize), .m_awburst(a_awburst),
        .m_awvalid(a_awvalid), .m_awready(a_awready),
        .m_wdata(a_wdata), .m_wstrb(a_wstrb),
        .m_wlast(a_wlast), .m_wvalid(a_wvalid),
        .m_wready(a_wready),
        .m_bresp(a_bresp), .m_bvalid(a_bvalid),
        .m_bready(a_bready),
        .m_araddr(a_araddr), .m_arlen(a_arlen),
        .m_arsize(a_arsize), .m_arburst(a_arburst),
        .m_arvalid(a_arvalid), .m_arready(a_arready),
        .m_rdata(a_rdata), .m_rresp(a_rresp),
        .m_rlast(a_rlast), .m_rvalid(a_rvalid),
        .m_rready(a_rready)
    );

    axi_interconnect_shell u_axi_interconnect (
        .clk       (clk),
        .reset_n   (reset_n),
        .s_awaddr  (a_awaddr),
        .s_awlen   (a_awlen),
        .s_awsize  (a_awsize),
        .s_awburst (a_awburst),
        .s_awvalid (a_awvalid),
        .s_awready (a_awready),
        .s_wdata   (a_wdata),
        .s_wstrb   (a_wstrb),
        .s_wlast   (a_wlast),
        .s_wvalid  (a_wvalid),
        .s_wready  (a_wready),
        .s_bresp   (a_bresp),
        .s_bvalid  (a_bvalid),
        .s_bready  (a_bready),
        .s_araddr  (a_araddr),
        .s_arlen   (a_arlen),
        .s_arsize  (a_arsize),
        .s_arburst (a_arburst),
        .s_arvalid (a_arvalid),
        .s_arready (a_arready),
        .s_rdata   (a_rdata),
        .s_rresp   (a_rresp),
        .s_rlast   (a_rlast),
        .s_rvalid  (a_rvalid),
        .s_rready  (a_rready),
        .dma_cfg_wr_en(dma_cfg_wr_en),
        .dma_cfg_wr_offset(dma_cfg_wr_offset),
        .dma_cfg_wr_data(dma_cfg_wr_data),
        .dma_cfg_rd_offset(dma_cfg_rd_offset),
        .dma_cfg_rd_data(dma_cfg_rd_data),
        .uart_rx(uart_rx),
        .uart_tx(uart_tx),
        .uart_irq(uart_irq),
        .uart_rx_dma_req(uart_rx_dma_req),
        .uart_tx_dma_req(uart_tx_dma_req),
        .error_seen(fabric_error),
        .fir_irq_done(fir_irq_done),
        .fir_irq_ovf (fir_irq_ovf)
    );

    // UART/FIR keep the low interrupt bits. Six DMA channel interrupts occupy
    // IRQ[13:8], matching SOC_IRQ_DMA_BASE in soc_addr_map.vh.
    assign irq[`SOC_IRQ_UART0]    = uart_irq;
    assign irq[`SOC_IRQ_FIR_DONE] = fir_irq_done;
    assign irq[`SOC_IRQ_FIR_OVF]  = fir_irq_ovf;
    assign irq[7:3]               = 5'd0;
    assign irq[`SOC_IRQ_DMA_BASE +: 6] = dma_irq;
    assign irq[31:14]             = 18'd0;

endmodule
