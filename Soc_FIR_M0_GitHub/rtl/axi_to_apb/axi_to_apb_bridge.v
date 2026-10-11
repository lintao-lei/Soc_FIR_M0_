`timescale 1ns/1ps

// One-outstanding AXI4-to-APB3 bridge for memory-mapped peripherals.
// This first project version intentionally accepts one aligned 32-bit beat:
// AWLEN/ARLEN=0, AWSIZE/ARSIZE=4 bytes, INCR, WSTRB=1111 and WLAST=1.
// Unsupported requests are completed with SLVERR and never reach APB.
module axi_to_apb_bridge (
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

    output wire [11:0] paddr,
    output wire        psel,
    output wire        penable,
    output wire        pwrite,
    output wire [31:0] pwdata,
    input  wire [31:0] prdata,
    input  wire        pready,
    input  wire        pslverr
);
    localparam [1:0] AXI_RESP_OKAY   = 2'b00;
    localparam [1:0] AXI_RESP_SLVERR = 2'b10;
    localparam [1:0] AXI_BURST_INCR  = 2'b01;
    localparam [2:0] AXI_SIZE_4BYTE  = 3'b010;

    localparam [2:0] ST_IDLE       = 3'd0;
    localparam [2:0] ST_APB_SETUP  = 3'd1;
    localparam [2:0] ST_APB_ACCESS = 3'd2;
    localparam [2:0] ST_AXI_B      = 3'd3;
    localparam [2:0] ST_AXI_R      = 3'd4;

    reg [2:0] state;

    // AXI AW and W are independent, so they require independent holding
    // registers. A transaction starts only after both have been received.
    reg        aw_received;
    reg [31:0] awaddr_reg;
    reg        aw_error_reg;
    reg        w_received;
    reg [31:0] wdata_reg;
    reg        w_error_reg;

    // APB request registers remain stable in both SETUP and ACCESS.
    reg [11:0] apb_addr_reg;
    reg [31:0] apb_wdata_reg;
    reg        apb_write_reg;

    // AXI response registers remain stable while BREADY/RREADY are low.
    reg [ 1:0] bresp_reg;
    reg [31:0] rdata_reg;
    reg [ 1:0] rresp_reg;

    wire idle = (state == ST_IDLE);

    // Writes win when a read and write are offered together. This bridge can
    // nevertheless accept AW-first, W-first, or AW and W on the same cycle.
    assign s_awready = reset_n && idle && !aw_received;
    assign s_wready  = reset_n && idle && !w_received;
    assign s_arready = reset_n && idle && !aw_received && !w_received &&
                       !s_awvalid && !s_wvalid;

    wire aw_handshake = s_awvalid && s_awready;
    wire w_handshake  = s_wvalid  && s_wready;
    wire ar_handshake = s_arvalid && s_arready;
    wire b_handshake  = s_bvalid  && s_bready;
    wire r_handshake  = s_rvalid  && s_rready;

    wire have_aw = aw_received || aw_handshake;
    wire have_w  = w_received  || w_handshake;
    wire write_complete = idle && have_aw && have_w;

    wire incoming_aw_error = (s_awlen   != 8'd0) ||
                             (s_awsize  != AXI_SIZE_4BYTE) ||
                             (s_awburst != AXI_BURST_INCR) ||
                             (s_awaddr[1:0] != 2'b00);
    wire incoming_w_error = !s_wlast || (s_wstrb != 4'b1111);
    wire incoming_ar_error = (s_arlen   != 8'd0) ||
                             (s_arsize  != AXI_SIZE_4BYTE) ||
                             (s_arburst != AXI_BURST_INCR) ||
                             (s_araddr[1:0] != 2'b00);

    wire selected_aw_error = aw_received ? aw_error_reg : incoming_aw_error;
    wire selected_w_error  = w_received  ? w_error_reg  : incoming_w_error;
    wire selected_write_error = selected_aw_error || selected_w_error;

    assign s_bvalid = (state == ST_AXI_B);
    assign s_bresp  = bresp_reg;
    assign s_rvalid = (state == ST_AXI_R);
    assign s_rdata  = rdata_reg;
    assign s_rresp  = rresp_reg;
    assign s_rlast  = (state == ST_AXI_R);

    assign paddr   = apb_addr_reg;
    assign pwdata  = apb_wdata_reg;
    assign pwrite  = apb_write_reg;
    assign psel    = (state == ST_APB_SETUP) || (state == ST_APB_ACCESS);
    assign penable = (state == ST_APB_ACCESS);

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state           <= ST_IDLE;
            aw_received     <= 1'b0;
            awaddr_reg      <= 32'd0;
            aw_error_reg    <= 1'b0;
            w_received      <= 1'b0;
            wdata_reg       <= 32'd0;
            w_error_reg     <= 1'b0;
            apb_addr_reg    <= 12'd0;
            apb_wdata_reg   <= 32'd0;
            apb_write_reg   <= 1'b0;
            bresp_reg       <= AXI_RESP_OKAY;
            rdata_reg       <= 32'd0;
            rresp_reg       <= AXI_RESP_OKAY;
        end else begin
            if (aw_handshake) begin
                aw_received  <= 1'b1;
                awaddr_reg   <= s_awaddr;
                aw_error_reg <= incoming_aw_error;
            end

            if (w_handshake) begin
                w_received  <= 1'b1;
                wdata_reg   <= s_wdata;
                w_error_reg <= incoming_w_error;
            end

            case (state)
                ST_IDLE: begin
                    if (write_complete) begin
                        aw_received <= 1'b0;
                        w_received  <= 1'b0;
                        if (selected_write_error) begin
                            bresp_reg <= AXI_RESP_SLVERR;
                            state <= ST_AXI_B;
                        end else begin
                            apb_addr_reg  <= aw_received ?
                                               awaddr_reg[11:0] : s_awaddr[11:0];
                            apb_wdata_reg <= w_received ? wdata_reg : s_wdata;
                            apb_write_reg <= 1'b1;
                            state <= ST_APB_SETUP;
                        end
                    end else if (ar_handshake) begin
                        if (incoming_ar_error) begin
                            rdata_reg <= 32'd0;
                            rresp_reg <= AXI_RESP_SLVERR;
                            state <= ST_AXI_R;
                        end else begin
                            apb_addr_reg  <= s_araddr[11:0];
                            apb_wdata_reg <= 32'd0;
                            apb_write_reg <= 1'b0;
                            state <= ST_APB_SETUP;
                        end
                    end
                end

                // APB SETUP: PSEL=1, PENABLE=0 for exactly one clock.
                ST_APB_SETUP: begin
                    state <= ST_APB_ACCESS;
                end

                // APB ACCESS: hold the entire request until PREADY=1.
                ST_APB_ACCESS: begin
                    if (pready) begin
                        if (apb_write_reg) begin
                            bresp_reg <= pslverr ? AXI_RESP_SLVERR :
                                                  AXI_RESP_OKAY;
                            state <= ST_AXI_B;
                        end else begin
                            rdata_reg <= prdata;
                            rresp_reg <= pslverr ? AXI_RESP_SLVERR :
                                                  AXI_RESP_OKAY;
                            state <= ST_AXI_R;
                        end
                    end
                end

                ST_AXI_B: begin
                    if (b_handshake)
                        state <= ST_IDLE;
                end

                ST_AXI_R: begin
                    if (r_handshake)
                        state <= ST_IDLE;
                end

                default: begin
                    state <= ST_IDLE;
                    aw_received <= 1'b0;
                    w_received <= 1'b0;
                end
            endcase
        end
    end
endmodule
