`timescale 1ns/1ps

// Complete AXI slave for the UART address window. System-level address
// decoding remains in axi_interconnect_shell; this module translates the
// selected AXI transaction to APB and contains the APB UART peripheral.
module axi_apb_uart_subsystem #(
    parameter integer CLKS_PER_BIT = 434
) (
    input  wire        clk,
    input  wire        reset_n,

    input  wire [31:0] s_awaddr,
    input  wire [ 7:0] s_awlen,
    input  wire [ 2:0] s_awsize,
    input  wire [ 1:0] s_awburst,
    input  wire        s_awvalid,
    output wire        s_awready,
    input  wire [31:0] s_wdata,
    input  wire [ 3:0] s_wstrb,
    input  wire        s_wlast,
    input  wire        s_wvalid,
    output wire        s_wready,
    output wire [ 1:0] s_bresp,
    output wire        s_bvalid,
    input  wire        s_bready,

    input  wire [31:0] s_araddr,
    input  wire [ 7:0] s_arlen,
    input  wire [ 2:0] s_arsize,
    input  wire [ 1:0] s_arburst,
    input  wire        s_arvalid,
    output wire        s_arready,
    output wire [31:0] s_rdata,
    output wire [ 1:0] s_rresp,
    output wire        s_rlast,
    output wire        s_rvalid,
    input  wire        s_rready,

    input  wire        uart_rx,
    output wire        uart_tx,
    output wire        uart_irq,
    output wire        uart_rx_dma_req,
    output wire        uart_tx_dma_req
);
    wire [11:0] paddr;
    wire        psel;
    wire        penable;
    wire        pwrite;
    wire [31:0] pwdata;
    wire [31:0] prdata;
    wire        pready;
    wire        pslverr;

    axi_to_apb_bridge u_bridge (
        .clk(clk), .reset_n(reset_n),
        .s_awaddr(s_awaddr), .s_awlen(s_awlen),
        .s_awsize(s_awsize), .s_awburst(s_awburst),
        .s_awvalid(s_awvalid), .s_awready(s_awready),
        .s_wdata(s_wdata), .s_wstrb(s_wstrb), .s_wlast(s_wlast),
        .s_wvalid(s_wvalid), .s_wready(s_wready),
        .s_bresp(s_bresp), .s_bvalid(s_bvalid), .s_bready(s_bready),
        .s_araddr(s_araddr), .s_arlen(s_arlen),
        .s_arsize(s_arsize), .s_arburst(s_arburst),
        .s_arvalid(s_arvalid), .s_arready(s_arready),
        .s_rdata(s_rdata), .s_rresp(s_rresp), .s_rlast(s_rlast),
        .s_rvalid(s_rvalid), .s_rready(s_rready),
        .paddr(paddr), .psel(psel), .penable(penable),
        .pwrite(pwrite), .pwdata(pwdata),
        .prdata(prdata), .pready(pready), .pslverr(pslverr)
    );

    apb_uart_shell #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_uart (
        .pclk(clk), .preset_n(reset_n),
        .paddr(paddr), .psel(psel), .penable(penable),
        .pwrite(pwrite), .pwdata(pwdata),
        .prdata(prdata), .pready(pready), .pslverr(pslverr),
        .uart_rx(uart_rx), .uart_tx(uart_tx), .irq(uart_irq),
        .rx_dma_req(uart_rx_dma_req),
        .tx_dma_req(uart_tx_dma_req)
    );
endmodule
