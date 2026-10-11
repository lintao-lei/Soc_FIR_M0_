`timescale 1ns/1ps

// Testbench for the current, legal-request stage of axi_burst_sram.
// It checks real SRAM data, INCR address progression, byte strobes,
// response backpressure, RLAST, and simultaneous AW/AR arbitration.
module tb_axi_burst_sram_current;

    localparam [1:0] AXI_RESP_OKAY  = 2'b00;
    localparam [1:0] AXI_BURST_INCR = 2'b01;
    localparam [2:0] AXI_SIZE_4BYTE = 3'b010;

    reg clk;
    reg reset_n;

    reg  [31:0] s_awaddr;
    reg  [ 7:0] s_awlen;
    reg  [ 2:0] s_awsize;
    reg  [ 1:0] s_awburst;
    reg         s_awvalid;
    wire        s_awready;

    reg  [31:0] s_wdata;
    reg  [ 3:0] s_wstrb;
    reg         s_wlast;
    reg         s_wvalid;
    wire        s_wready;

    wire [ 1:0] s_bresp;
    wire        s_bvalid;
    reg         s_bready;

    reg  [31:0] s_araddr;
    reg  [ 7:0] s_arlen;
    reg  [ 2:0] s_arsize;
    reg  [ 1:0] s_arburst;
    reg         s_arvalid;
    wire        s_arready;

    wire [31:0] s_rdata;
    wire [ 1:0] s_rresp;
    wire        s_rlast;
    wire        s_rvalid;
    reg         s_rready;

    integer checks;
    integer errors;
    integer beat;

    reg [31:0] held_rdata;
    reg [ 1:0] held_rresp;
    reg        held_rlast;

    axi_burst_sram #(
        .SRAM_ADDR_WIDTH(8)
    ) dut (
        .clk       (clk),
        .reset_n   (reset_n),

        .s_awaddr  (s_awaddr),
        .s_awlen   (s_awlen),
        .s_awsize  (s_awsize),
        .s_awburst (s_awburst),
        .s_awvalid (s_awvalid),
        .s_awready (s_awready),

        .s_wdata   (s_wdata),
        .s_wstrb   (s_wstrb),
        .s_wlast   (s_wlast),
        .s_wvalid  (s_wvalid),
        .s_wready  (s_wready),

        .s_bresp   (s_bresp),
        .s_bvalid  (s_bvalid),
        .s_bready  (s_bready),

        .s_araddr  (s_araddr),
        .s_arlen   (s_arlen),
        .s_arsize  (s_arsize),
        .s_arburst (s_arburst),
        .s_arvalid (s_arvalid),
        .s_arready (s_arready),

        .s_rdata   (s_rdata),
        .s_rresp   (s_rresp),
        .s_rlast   (s_rlast),
        .s_rvalid  (s_rvalid),
        .s_rready  (s_rready)
    );

    always #5 clk = ~clk;

    task check;
        input condition;
        input [8*120-1:0] message;
        begin
            checks = checks + 1;
            if (condition === 1'b1) begin
                $display("[%0t] CHECK %0d PASS: %0s", $time, checks, message);
            end else begin
                errors = errors + 1;
                $display("[%0t] CHECK %0d FAIL: %0s", $time, checks, message);
            end
        end
    endtask

    task axi_write_burst;
        input [31:0] address;
        input integer beat_count;
        input [31:0] data_base;
        input [31:0] data_step;
        input [ 3:0] strobe;
        input integer b_stall_cycles;
        integer i;
        reg [1:0] held_bresp;
        begin
            @(negedge clk);
            s_awaddr  = address;
            s_awlen   = beat_count - 1;
            s_awsize  = AXI_SIZE_4BYTE;
            s_awburst = AXI_BURST_INCR;
            s_awvalid = 1'b1;

            @(posedge clk);
            while (!(s_awvalid && s_awready))
                @(posedge clk);

            @(negedge clk);
            s_awvalid = 1'b0;

            for (i = 0; i < beat_count; i = i + 1) begin
                @(negedge clk);
                s_wdata  = data_base + i * data_step;
                s_wstrb  = strobe;
                s_wlast  = (i == beat_count - 1);
                s_wvalid = 1'b1;

                @(posedge clk);
                while (!(s_wvalid && s_wready))
                    @(posedge clk);

                if ((i != beat_count - 1) && s_bvalid) begin
                    errors = errors + 1;
                    $display("[%0t] FAIL: BVALID appeared before final W beat", $time);
                end

                @(negedge clk);
                s_wvalid = 1'b0;
                s_wlast  = 1'b0;
            end

            while (s_bvalid !== 1'b1)
                @(negedge clk);

            held_bresp = s_bresp;
            repeat (b_stall_cycles) begin
                @(posedge clk);
                check(s_bvalid === 1'b1,
                      "BVALID remains asserted while BREADY is low");
                check(s_bresp === held_bresp,
                      "BRESP remains stable while BREADY is low");
            end

            check(s_bresp === AXI_RESP_OKAY,
                  "legal write burst returns OKAY");

            @(negedge clk);
            s_bready = 1'b1;
            @(posedge clk);
            check(s_bvalid && s_bready,
                  "B channel handshake occurs");
            #1;
            check(s_bvalid === 1'b0,
                  "BVALID clears after B handshake");
            @(negedge clk);
            s_bready = 1'b0;
        end
    endtask

    task axi_read_burst_expect;
        input [31:0] address;
        input integer beat_count;
        input [31:0] data_base;
        input [31:0] data_step;
        input integer apply_backpressure;
        integer i;
        integer k;
        reg [31:0] expected_data;
        begin
            @(negedge clk);
            s_araddr  = address;
            s_arlen   = beat_count - 1;
            s_arsize  = AXI_SIZE_4BYTE;
            s_arburst = AXI_BURST_INCR;
            s_arvalid = 1'b1;

            @(posedge clk);
            while (!(s_arvalid && s_arready))
                @(posedge clk);

            @(negedge clk);
            s_arvalid = 1'b0;
            s_rready  = 1'b0;

            for (i = 0; i < beat_count; i = i + 1) begin
                while (s_rvalid !== 1'b1)
                    @(negedge clk);

                if (apply_backpressure && ((i & 1) == 0)) begin
                    held_rdata = s_rdata;
                    held_rresp = s_rresp;
                    held_rlast = s_rlast;

                    for (k = 0; k < 2; k = k + 1) begin
                        @(posedge clk);
                        check(s_rvalid === 1'b1,
                              "RVALID remains asserted while RREADY is low");
                        check(s_rdata === held_rdata,
                              "RDATA remains stable while RREADY is low");
                        check(s_rresp === held_rresp,
                              "RRESP remains stable while RREADY is low");
                        check(s_rlast === held_rlast,
                              "RLAST remains stable while RREADY is low");
                    end
                    @(negedge clk);
                end

                s_rready = 1'b1;
                @(posedge clk);
                while (!(s_rvalid && s_rready))
                    @(posedge clk);

                expected_data = data_base + i * data_step;
                check(s_rresp === AXI_RESP_OKAY,
                      "legal read beat returns OKAY");
                check(s_rdata === expected_data,
                      "read data matches written data");
                check(s_rlast === (i == beat_count - 1),
                      "RLAST appears only on the final beat");

                @(negedge clk);
                s_rready = 1'b0;
            end
        end
    endtask

    // Explicitly checks the one-transaction-at-a-time arbitration rule.
    // AW has priority when AWVALID and ARVALID arrive together.
    task test_simultaneous_aw_ar;
        begin
            $display("");
            $display("TEST: simultaneous AWVALID and ARVALID arbitration");

            @(negedge clk);
            s_awaddr  = 32'h0000_00C0;
            s_awlen   = 8'd0;
            s_awsize  = AXI_SIZE_4BYTE;
            s_awburst = AXI_BURST_INCR;
            s_awvalid = 1'b1;

            s_araddr  = 32'h0000_0000;
            s_arlen   = 8'd0;
            s_arsize  = AXI_SIZE_4BYTE;
            s_arburst = AXI_BURST_INCR;
            s_arvalid = 1'b1;
            #1;

            check(s_awready === 1'b1,
                  "AW is selected when AW and AR arrive together");
            check(s_arready === 1'b0,
                  "ARREADY stays low when simultaneous AW has priority");

            @(posedge clk);
            @(negedge clk);
            s_awvalid = 1'b0;
            s_arvalid = 1'b0;

            // Complete the accepted single-beat write so the DUT returns idle.
            s_wdata  = 32'hCAFE_BABE;
            s_wstrb  = 4'b1111;
            s_wlast  = 1'b1;
            s_wvalid = 1'b1;
            @(posedge clk);
            while (!(s_wvalid && s_wready))
                @(posedge clk);
            @(negedge clk);
            s_wvalid = 1'b0;
            s_wlast  = 1'b0;

            while (s_bvalid !== 1'b1)
                @(negedge clk);
            s_bready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            s_bready = 1'b0;
        end
    endtask

    initial begin
        clk       = 1'b0;
        reset_n   = 1'b0;

        s_awaddr  = 32'd0;
        s_awlen   = 8'd0;
        s_awsize  = AXI_SIZE_4BYTE;
        s_awburst = AXI_BURST_INCR;
        s_awvalid = 1'b0;

        s_wdata   = 32'd0;
        s_wstrb   = 4'd0;
        s_wlast   = 1'b0;
        s_wvalid  = 1'b0;
        s_bready  = 1'b0;

        s_araddr  = 32'd0;
        s_arlen   = 8'd0;
        s_arsize  = AXI_SIZE_4BYTE;
        s_arburst = AXI_BURST_INCR;
        s_arvalid = 1'b0;
        s_rready  = 1'b0;

        checks = 0;
        errors = 0;

        $display("");
        $display("============================================================");
        $display("Starting current-stage AXI burst SRAM simulation");
        $display("============================================================");

        repeat (5) @(posedge clk);
        @(negedge clk);
        reset_n = 1'b1;
        repeat (2) @(posedge clk);

        check(s_awready === 1'b1,
              "AWREADY is high after reset while idle");
        check(s_arready === 1'b1,
              "ARREADY is high after reset while idle");

        $display("");
        $display("TEST 1: single-beat write/read with B backpressure");
        axi_write_burst(32'h0000_0000, 1,
                        32'h1122_3344, 32'd0, 4'b1111, 3);
        axi_read_burst_expect(32'h0000_0000, 1,
                              32'h1122_3344, 32'd0, 1);

        $display("");
        $display("TEST 2: four-beat INCR write/read with R backpressure");
        axi_write_burst(32'h0000_0040, 4,
                        32'h4000_0000, 32'h0101_0101, 4'b1111, 2);
        axi_read_burst_expect(32'h0000_0040, 4,
                              32'h4000_0000, 32'h0101_0101, 1);

        $display("");
        $display("TEST 3: eight-beat INCR write/read");
        axi_write_burst(32'h0000_0080, 8,
                        32'h8000_0000, 32'h0000_0011, 4'b1111, 0);
        axi_read_burst_expect(32'h0000_0080, 8,
                              32'h8000_0000, 32'h0000_0011, 1);

        $display("");
        $display("TEST 4: sixteen-beat INCR write/read");
        axi_write_burst(32'h0000_0100, 16,
                        32'h1600_0000, 32'h0000_0101, 4'b1111, 1);
        axi_read_burst_expect(32'h0000_0100, 16,
                              32'h1600_0000, 32'h0000_0101, 1);

        $display("");
        $display("TEST 5: byte strobes");
        axi_write_burst(32'h0000_0020, 1,
                        32'hAABB_CCDD, 32'd0, 4'b1111, 0);
        axi_write_burst(32'h0000_0020, 1,
                        32'h0000_0055, 32'd0, 4'b0001, 0);
        axi_write_burst(32'h0000_0020, 1,
                        32'h0000_6600, 32'd0, 4'b0010, 0);
        axi_read_burst_expect(32'h0000_0020, 1,
                              32'hAABB_6655, 32'd0, 1);

        test_simultaneous_aw_ar();

        $display("");
        $display("============================================================");
        $display("Checks: %0d", checks);
        $display("Errors: %0d", errors);
        if (errors == 0)
            $display("TEST PASS");
        else
            $display("TEST FAIL: %0d error(s)", errors);
        $display("============================================================");
        $finish;
    end

    initial begin
        #100000;
        $display("TEST FAIL: timeout at %0t", $time);
        $finish;
    end

endmodule


