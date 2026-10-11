`timescale 1ns/1ps

module cortex_m0_subsystem (
    input  wire        clk,
    input  wire        reset_n,
    input  wire [31:0] irq,

    output wire [31:0] haddr,
    output wire [ 2:0] hburst,
    output wire        hmastlock,
    output wire [ 3:0] hprot,
    output wire [ 2:0] hsize,
    output wire [ 1:0] htrans,
    output wire [31:0] hwdata,
    output wire        hwrite,
    input  wire [31:0] hrdata,
    input  wire        hready,
    input  wire        hresp,

    output wire        sleeping,
    output wire        lockup,
    output wire        sysresetreq
);

    // Cortex-M0 DesignStart integration wrapper. Do not modify
    // cortexm0ds_logic.v; keep all board-specific logic outside the core.
    CORTEXM0INTEGRATION u_cortex_m0 (
        .FCLK          (clk),
        .SCLK          (clk),
        .HCLK          (clk),
        .DCLK          (clk),
        .PORESETn      (reset_n),
        .DBGRESETn     (reset_n),
        .HRESETn       (reset_n),
        .SWCLKTCK      (1'b0),
        .nTRST         (1'b1),

        .HADDR         (haddr),
        .HBURST        (hburst),
        .HMASTLOCK     (hmastlock),
        .HPROT         (hprot),
        .HSIZE         (hsize),
        .HTRANS        (htrans),
        .HWDATA        (hwdata),
        .HWRITE        (hwrite),
        .HRDATA        (hrdata),
        .HREADY        (hready),
        .HRESP         (hresp),
        .HMASTER       (),

        .CODENSEQ      (),
        .CODEHINTDE    (),
        .SPECHTRANS    (),

        // Debug is tied off in the framework. Expose SWDIO/SWCLK from
        // soc_top later if interactive processor debug is required.
        .SWDITMS       (1'b1),
        .TDI           (1'b0),
        .SWDO          (),
        .SWDOEN        (),
        .TDO           (),
        .nTDOEN        (),
        .DBGRESTART    (1'b0),
        .DBGRESTARTED  (),
        .EDBGRQ        (1'b0),
        .HALTED        (),

        .NMI           (1'b0),
        .IRQ           (irq),
        .TXEV          (),
        .RXEV          (1'b0),
        .LOCKUP        (lockup),
        .SYSRESETREQ   (sysresetreq),
        .STCALIB       (26'd0),
        .STCLKEN       (1'b1),
        .IRQLATENCY    (8'd0),
        .ECOREVNUM     (28'd0),

        .GATEHCLK      (),
        .SLEEPING      (sleeping),
        .SLEEPDEEP     (),
        .WAKEUP        (),
        .WICSENSE      (),
        .SLEEPHOLDREQn (1'b1),
        .SLEEPHOLDACKn (),
        .WICENREQ      (1'b0),
        .WICENACK      (),
        .CDBGPWRUPREQ  (),
        .CDBGPWRUPACK  (1'b0),

        .SE            (1'b0),
        .RSTBYPASS     (1'b0)
    );

endmodule
