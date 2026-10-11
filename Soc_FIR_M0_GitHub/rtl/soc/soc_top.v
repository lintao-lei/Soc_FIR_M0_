`timescale 1ns/1ps

module soc_top (
    input  wire clk_board,
    input  wire reset_n,
    input  wire uart_rx,
    output wire uart_tx,
    output wire led_run,
    output wire led_error
);

    wire clk_sys;
    wire reset_sys_n;

    wire [31:0] cpu_haddr;
    wire [ 2:0] cpu_hburst;
    wire        cpu_hmastlock;
    wire [ 3:0] cpu_hprot;
    wire [ 2:0] cpu_hsize;
    wire [ 1:0] cpu_htrans;
    wire [31:0] cpu_hwdata;
    wire        cpu_hwrite;
    wire [31:0] cpu_hrdata;
    wire        cpu_hready;
    wire        cpu_hresp;
    wire [31:0] irq;
    wire        cpu_sleeping;
    wire        cpu_lockup;
    wire        cpu_sysresetreq;
    wire        fabric_error;

    soc_clock_reset u_clock_reset (
        .clk_board   (clk_board),
        .reset_n     (reset_n),
        .clk_sys     (clk_sys),
        .reset_sys_n (reset_sys_n)
    );

    cortex_m0_subsystem u_cpu (
        .clk         (clk_sys),
        .reset_n     (reset_sys_n),
        .irq         (irq),
        .haddr       (cpu_haddr),
        .hburst      (cpu_hburst),
        .hmastlock   (cpu_hmastlock),
        .hprot       (cpu_hprot),
        .hsize       (cpu_hsize),
        .htrans      (cpu_htrans),
        .hwdata      (cpu_hwdata),
        .hwrite      (cpu_hwrite),
        .hrdata      (cpu_hrdata),
        .hready      (cpu_hready),
        .hresp       (cpu_hresp),
        .sleeping    (cpu_sleeping),
        .lockup      (cpu_lockup),
        .sysresetreq (cpu_sysresetreq)
    );

    soc_fabric_shell u_fabric (
        .clk         (clk_sys),
        .reset_n     (reset_sys_n),
        .haddr       (cpu_haddr),
        .hburst      (cpu_hburst),
        .hmastlock   (cpu_hmastlock),
        .hprot       (cpu_hprot),
        .hsize       (cpu_hsize),
        .htrans      (cpu_htrans),
        .hwdata      (cpu_hwdata),
        .hwrite      (cpu_hwrite),
        .hrdata      (cpu_hrdata),
        .hready      (cpu_hready),
        .hresp       (cpu_hresp),
        .uart_rx     (uart_rx),
        .uart_tx     (uart_tx),
        .irq         (irq),
        .fabric_error(fabric_error)
    );

    // These outputs make early board bring-up observable and retain the CPU
    // hierarchy during synthesis. Replace led_run with a software-controlled
    // system register once the memory and bus path are implemented.
    assign led_run   = cpu_haddr[2] ^ cpu_sleeping;
    assign led_error = cpu_lockup | cpu_sysresetreq | fabric_error;

endmodule
