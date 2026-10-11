`timescale 1ns/1ps

// FIR subsystem wrapper.
//
// Connects the AXI4-Lite control plane, AXI4 data window, private AXI-Stream
// sample/result path, and clear/enable coordination.  The FIR arithmetic core
// remains the 81-tap implementation delivered with the original design.
module fir_subsystem #(
    parameter integer N_TAP      = 81,
    parameter integer FIFO_DEPTH = 32
)(
    input  wire        aclk,
    input  wire        aresetn,

    // AXI4-Lite control/register interface.
    input  wire [11:0] ctrl_awaddr,
    input  wire        ctrl_awvalid,
    output wire        ctrl_awready,
    input  wire [31:0] ctrl_wdata,
    input  wire [ 3:0] ctrl_wstrb,
    input  wire        ctrl_wvalid,
    output wire        ctrl_wready,
    output wire [ 1:0] ctrl_bresp,
    output wire        ctrl_bvalid,
    input  wire        ctrl_bready,

    input  wire [11:0] ctrl_araddr,
    input  wire        ctrl_arvalid,
    output wire        ctrl_arready,
    output wire [31:0] ctrl_rdata,
    output wire [ 1:0] ctrl_rresp,
    output wire        ctrl_rvalid,
    input  wire        ctrl_rready,

    // AXI4 sample/result data window.
    input  wire [31:0] data_awaddr,
    input  wire [ 7:0] data_awlen,
    input  wire [ 2:0] data_awsize,
    input  wire [ 1:0] data_awburst,
    input  wire        data_awvalid,
    output wire        data_awready,

    input  wire [31:0] data_wdata,
    input  wire [ 3:0] data_wstrb,
    input  wire        data_wlast,
    input  wire        data_wvalid,
    output wire        data_wready,

    output wire [ 1:0] data_bresp,
    output wire        data_bvalid,
    input  wire        data_bready,

    input  wire [31:0] data_araddr,
    input  wire [ 7:0] data_arlen,
    input  wire [ 2:0] data_arsize,
    input  wire [ 1:0] data_arburst,
    input  wire        data_arvalid,
    output wire        data_arready,

    output wire [31:0] data_rdata,
    output wire [ 1:0] data_rresp,
    output wire        data_rlast,
    output wire        data_rvalid,
    input  wire        data_rready,

    output wire        irq_done,
    output wire        irq_ovf
);

    // Private AXI-Stream link between the bus-facing data mover and FIR core.
    wire signed [15:0] fir_s_tdata;
    wire               fir_s_tvalid;
    wire               fir_s_tready;
    wire signed [31:0] fir_m_tdata;
    wire               fir_m_tvalid;
    wire               fir_m_tready;
    wire               fir_enabled;
    wire               clear_request;
    wire               clear_data;
    wire               data_busy;

    fir_81tap_axi #(
        .N_TAP(N_TAP)
    ) u_fir_ctrl (
        .aclk            (aclk),
        .aresetn         (aresetn),

        .s_axil_awaddr   (ctrl_awaddr),
        .s_axil_awvalid  (ctrl_awvalid),
        .s_axil_awready  (ctrl_awready),
        .s_axil_wdata    (ctrl_wdata),
        .s_axil_wstrb    (ctrl_wstrb),
        .s_axil_wvalid   (ctrl_wvalid),
        .s_axil_wready   (ctrl_wready),
        .s_axil_bresp    (ctrl_bresp),
        .s_axil_bvalid   (ctrl_bvalid),
        .s_axil_bready   (ctrl_bready),

        .s_axil_araddr   (ctrl_araddr),
        .s_axil_arvalid  (ctrl_arvalid),
        .s_axil_arready  (ctrl_arready),
        .s_axil_rdata    (ctrl_rdata),
        .s_axil_rresp    (ctrl_rresp),
        .s_axil_rvalid   (ctrl_rvalid),
        .s_axil_rready   (ctrl_rready),

        .s_axis_tdata    (fir_s_tdata),
        .s_axis_tvalid   (fir_s_tvalid),
        .s_axis_tready   (fir_s_tready),
        .m_axis_tdata    (fir_m_tdata),
        .m_axis_tvalid   (fir_m_tvalid),
        .m_axis_tready   (fir_m_tready),

        .data_busy       (data_busy),
        .data_enabled    (fir_enabled),
        .data_clear_request(clear_request),
        .data_clear      (clear_data),

        .irq_done        (irq_done),
        .irq_ovf         (irq_ovf)
    );

    axi_fir_data #(
        .FIFO_DEPTH(FIFO_DEPTH)
    ) u_fir_data (
        .aclk            (aclk),
        .aresetn         (aresetn),

        .s_axi_awaddr    (data_awaddr),
        .s_axi_awlen     (data_awlen),
        .s_axi_awsize    (data_awsize),
        .s_axi_awburst   (data_awburst),
        .s_axi_awvalid   (data_awvalid),
        .s_axi_awready   (data_awready),
        .s_axi_wdata     (data_wdata),
        .s_axi_wstrb     (data_wstrb),
        .s_axi_wlast     (data_wlast),
        .s_axi_wvalid    (data_wvalid),
        .s_axi_wready    (data_wready),
        .s_axi_bresp     (data_bresp),
        .s_axi_bvalid    (data_bvalid),
        .s_axi_bready    (data_bready),

        .s_axi_araddr    (data_araddr),
        .s_axi_arlen     (data_arlen),
        .s_axi_arsize    (data_arsize),
        .s_axi_arburst   (data_arburst),
        .s_axi_arvalid   (data_arvalid),
        .s_axi_arready   (data_arready),
        .s_axi_rdata     (data_rdata),
        .s_axi_rresp     (data_rresp),
        .s_axi_rlast     (data_rlast),
        .s_axi_rvalid    (data_rvalid),
        .s_axi_rready    (data_rready),

        .fir_s_tdata     (fir_s_tdata),
        .fir_s_tvalid    (fir_s_tvalid),
        .fir_s_tready    (fir_s_tready),
        .fir_m_tdata     (fir_m_tdata),
        .fir_m_tvalid    (fir_m_tvalid),
        .fir_m_tready    (fir_m_tready),
        .fir_enabled     (fir_enabled),
        .clear_request   (clear_request),
        .clear_data      (clear_data),
        .data_busy       (data_busy)
    );

endmodule
