`timescale 1ns/1ps

// Project-facing wrapper for the dual-FIFO APB UART.
module apb_uart_shell #(
    parameter integer CLKS_PER_BIT = 434
) (
    input  wire        pclk,
    input  wire        preset_n,
    input  wire [11:0] paddr,
    input  wire        psel,
    input  wire        penable,
    input  wire        pwrite,
    input  wire [31:0] pwdata,
    output wire [31:0] prdata,
    output wire        pready,
    output wire        pslverr,
    input  wire        uart_rx,
    output wire        uart_tx,
    output wire        irq,
    output wire        rx_dma_req,
    output wire        tx_dma_req
);
    apb_uart #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_apb_uart (
        .pclk(pclk), .preset_n(preset_n),
        .paddr(paddr), .psel(psel), .penable(penable),
        .pwrite(pwrite), .pwdata(pwdata),
        .prdata(prdata), .pready(pready), .pslverr(pslverr),
        .uart_rx(uart_rx), .uart_tx(uart_tx), .irq(irq),
        .rx_dma_req(rx_dma_req), .tx_dma_req(tx_dma_req)
    );
endmodule
