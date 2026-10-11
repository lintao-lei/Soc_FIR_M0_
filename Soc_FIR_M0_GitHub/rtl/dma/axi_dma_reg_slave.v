`timescale 1ns/1ps

// AXI4 slave for the six-channel DMA configuration register page.
// One transaction at a time, 32-bit aligned single-beat accesses only.
// Unsupported reads return ARLEN+1 SLVERR beats; unsupported writes drain
// through WLAST, then return one SLVERR B response.
module axi_dma_reg_slave #(
    parameter [31:0] BASE_ADDR = 32'h4000_E000
) (
    input  wire        clk,
    input  wire        reset_n,

    // AXI slave: write address
    input  wire [31:0] s_awaddr,
    input  wire [7:0]  s_awlen,
    input  wire [2:0]  s_awsize,
    input  wire [1:0]  s_awburst,
    input  wire        s_awvalid,
    output wire        s_awready,
    // AXI slave: write data
    input  wire [31:0] s_wdata,
    input  wire [3:0]  s_wstrb,
    input  wire        s_wlast,
    input  wire        s_wvalid,
    output wire        s_wready,
    // AXI slave: write response
    output wire [1:0]  s_bresp,
    output wire        s_bvalid,
    input  wire        s_bready,

    // AXI slave: read address
    input  wire [31:0] s_araddr,
    input  wire [7:0]  s_arlen,
    input  wire [2:0]  s_arsize,
    input  wire [1:0]  s_arburst,
    input  wire        s_arvalid,
    output wire        s_arready,
    // AXI slave: read data
    output wire [31:0] s_rdata,
    output wire [1:0]  s_rresp,
    output wire        s_rlast,
    output wire        s_rvalid,
    input  wire        s_rready,

    // Local interface to dma6_core (NOT another AXI bus)
    output wire        cfg_wr_en,
    output wire [11:0] cfg_wr_offset,
    output wire [31:0] cfg_wr_data,
    output wire [11:0] cfg_rd_offset,
    input  wire [31:0] cfg_rd_data
);
    localparam [1:0] OKAY   = 2'b00;
    localparam [1:0] SLVERR = 2'b10;
    localparam [2:0] CHANNEL_COUNT = 3'd6;

    reg        aw_saved;
    reg [31:0] awaddr_reg;
    reg [7:0]  awlen_reg;
    reg [2:0]  awsize_reg;
    reg [1:0]  awburst_reg;

    reg        w_any;
    reg        w_complete;
    reg [8:0]  w_count;
    reg [31:0] first_wdata_reg;
    reg [3:0]  first_wstrb_reg;

    reg        bvalid_reg;
    reg [1:0]  bresp_reg;
    reg        rvalid_reg;
    reg [8:0]  r_left;
    reg [31:0] rdata_reg;
    reg [1:0]  rresp_reg;

    // Write has priority if a read and write are offered simultaneously.
    // Once either W or AW is accepted, AR is blocked until the B handshake.
    assign s_awready = reset_n && !rvalid_reg && !bvalid_reg && !aw_saved;
    assign s_wready  = reset_n && !rvalid_reg && !bvalid_reg && !w_complete;
    assign s_arready = reset_n && !rvalid_reg && !bvalid_reg &&
                       !aw_saved && !w_any && !s_awvalid && !s_wvalid;

    wire aw_fire = s_awvalid && s_awready;
    wire w_fire  = s_wvalid  && s_wready;
    wire b_fire  = s_bvalid  && s_bready;
    wire ar_fire = s_arvalid && s_arready;
    wire r_fire  = s_rvalid  && s_rready;

    assign s_bvalid = bvalid_reg;
    assign s_bresp  = bresp_reg;
    assign s_rvalid = rvalid_reg;
    assign s_rdata  = rdata_reg;
    assign s_rresp  = rresp_reg;
    assign s_rlast  = rvalid_reg && (r_left == 9'd1);

    wire write_commit = aw_saved && w_complete && !bvalid_reg;

    // The 4 KiB DMA page contains six 0x40-byte channel windows:
    //   offset[8:6] = channel number 0..5
    //   offset[5:0] = register offset inside that channel
    // It also contains global scheduler/status registers at 0x180..0x190.
    wire [2:0] wr_channel = awaddr_reg[8:6];
    wire [5:0] wr_register_offset = awaddr_reg[5:0];
    wire wr_channel_valid = (awaddr_reg[11:9] == 3'b000) &&
                            (wr_channel < CHANNEL_COUNT);
    wire wr_register_valid =
        (wr_register_offset == 6'h00) || // SRC_ADDR
        (wr_register_offset == 6'h04) || // DST_ADDR
        (wr_register_offset == 6'h08) || // WORD_COUNT
        (wr_register_offset == 6'h0C) || // CONTROL
        (wr_register_offset == 6'h10);   // STATUS: W1C DONE/ERROR
    wire wr_global_valid = (awaddr_reg[11:0] == 12'h180); // GLOBAL_CONTROL
    wire wr_offset_valid = (wr_channel_valid && wr_register_valid) ||
                           wr_global_valid;
    wire write_ok = (awaddr_reg[31:12] == BASE_ADDR[31:12]) &&
                    (awaddr_reg[1:0] == 2'b00) &&
                    (awlen_reg == 8'd0) && (awsize_reg == 3'b010) &&
                    (awburst_reg == 2'b01) && (w_count == 9'd1) &&
                    (first_wstrb_reg == 4'b1111) && wr_offset_valid;

    // This is a one-cycle pulse once BOTH AW and all W beats are captured.
    assign cfg_wr_en     = write_commit && write_ok;
    assign cfg_wr_offset = awaddr_reg[11:0];
    assign cfg_wr_data   = first_wdata_reg;

    wire [2:0] rd_channel = s_araddr[8:6];
    wire [5:0] rd_register_offset = s_araddr[5:0];
    wire rd_channel_valid = (s_araddr[11:9] == 3'b000) &&
                            (rd_channel < CHANNEL_COUNT);
    wire rd_register_valid =
        (rd_register_offset == 6'h00) || // SRC_ADDR
        (rd_register_offset == 6'h04) || // DST_ADDR
        (rd_register_offset == 6'h08) || // WORD_COUNT
        (rd_register_offset == 6'h0C) || // CONTROL
        (rd_register_offset == 6'h10) || // STATUS
        (rd_register_offset == 6'h14) || // REMAINING
        (rd_register_offset == 6'h18) || // CURRENT_SRC
        (rd_register_offset == 6'h1C);   // CURRENT_DST
    wire rd_global_valid =
        (s_araddr[11:0] == 12'h180) || // GLOBAL_CONTROL
        (s_araddr[11:0] == 12'h184) || // PENDING_MASK
        (s_araddr[11:0] == 12'h188) || // BUSY_MASK
        (s_araddr[11:0] == 12'h18C) || // DONE_MASK
        (s_araddr[11:0] == 12'h190);   // ERROR_MASK
    wire rd_offset_valid = (rd_channel_valid && rd_register_valid) ||
                           rd_global_valid;
    wire read_ok = (s_araddr[31:12] == BASE_ADDR[31:12]) &&
                   (s_araddr[1:0] == 2'b00) &&
                   (s_arlen == 8'd0) && (s_arsize == 3'b010) &&
                   (s_arburst == 2'b01) && rd_offset_valid;

    // dma6_register_file returns combinational data for the selected offset.
    // Capture it on AR handshake so RDATA stays stable under RREADY=0.
    assign cfg_rd_offset = s_araddr[11:0];

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            aw_saved       <= 1'b0;
            awaddr_reg     <= 32'd0;
            awlen_reg      <= 8'd0;
            awsize_reg     <= 3'd0;
            awburst_reg    <= 2'd0;
            w_any          <= 1'b0;
            w_complete     <= 1'b0;
            w_count        <= 9'd0;
            first_wdata_reg <= 32'd0;
            first_wstrb_reg <= 4'd0;
            bvalid_reg     <= 1'b0;
            bresp_reg      <= OKAY;
            rvalid_reg     <= 1'b0;
            r_left         <= 9'd0;
            rdata_reg      <= 32'd0;
            rresp_reg      <= OKAY;
        end else begin
            if (aw_fire) begin
                aw_saved    <= 1'b1;
                awaddr_reg  <= s_awaddr;
                awlen_reg   <= s_awlen;
                awsize_reg  <= s_awsize;
                awburst_reg <= s_awburst;
            end

            if (w_fire) begin
                if (!w_any) begin
                    w_any           <= 1'b1;
                    first_wdata_reg <= s_wdata;
                    first_wstrb_reg <= s_wstrb;
                end
                if (w_count != 9'd256)
                    w_count <= w_count + 9'd1;
                if (s_wlast)
                    w_complete <= 1'b1;
            end

            if (write_commit) begin
                // The register core sees cfg_wr_en on this same clock edge.
                bvalid_reg <= 1'b1;
                bresp_reg  <= write_ok ? OKAY : SLVERR;
                aw_saved   <= 1'b0;
                w_any      <= 1'b0;
                w_complete <= 1'b0;
                w_count    <= 9'd0;
            end
            if (b_fire)
                bvalid_reg <= 1'b0;

            if (ar_fire) begin
                rvalid_reg <= 1'b1;
                r_left     <= {1'b0, s_arlen} + 9'd1;
                rdata_reg  <= read_ok ? cfg_rd_data : 32'd0;
                rresp_reg  <= read_ok ? OKAY : SLVERR;
            end else if (r_fire) begin
                if (r_left == 9'd1) begin
                    rvalid_reg <= 1'b0;
                    r_left     <= 9'd0;
                end else begin
                    r_left <= r_left - 9'd1;
                end
            end
        end
    end
endmodule






































