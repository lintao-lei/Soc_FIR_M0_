`timescale 1ns/1ps

// axi_burst_sram负向协议验收：
// 未对齐、非法Burst、超过16拍、跨4KiB、WLAST错误以及事务中复位。
module tb_axi_burst_sram_protocol_errors;
    localparam [1:0] RESP_OKAY   = 2'b00;
    localparam [1:0] RESP_SLVERR = 2'b10;
    localparam [1:0] BURST_FIXED = 2'b00;
    localparam [1:0] BURST_INCR  = 2'b01;
    localparam [1:0] BURST_WRAP  = 2'b10;
    localparam [2:0] SIZE_2BYTE  = 3'b001;
    localparam [2:0] SIZE_4BYTE  = 3'b010;

    reg clk = 1'b0;
    reg reset_n = 1'b0;

    reg  [31:0] s_awaddr = 32'd0;
    reg  [7:0]  s_awlen = 8'd0;
    reg  [2:0]  s_awsize = SIZE_4BYTE;
    reg  [1:0]  s_awburst = BURST_INCR;
    reg         s_awvalid = 1'b0;
    wire        s_awready;

    reg  [31:0] s_wdata = 32'd0;
    reg  [3:0]  s_wstrb = 4'd0;
    reg         s_wlast = 1'b0;
    reg         s_wvalid = 1'b0;
    wire        s_wready;

    wire [1:0]  s_bresp;
    wire        s_bvalid;
    reg         s_bready = 1'b0;

    reg  [31:0] s_araddr = 32'd0;
    reg  [7:0]  s_arlen = 8'd0;
    reg  [2:0]  s_arsize = SIZE_4BYTE;
    reg  [1:0]  s_arburst = BURST_INCR;
    reg         s_arvalid = 1'b0;
    wire        s_arready;

    wire [31:0] s_rdata;
    wire [1:0]  s_rresp;
    wire        s_rlast;
    wire        s_rvalid;
    reg         s_rready = 1'b0;

    integer checks = 0;
    integer errors = 0;
    integer b_count = 0;
    integer r_count = 0;
    reg [31:0] read_value;

    always #5 clk = ~clk;

    axi_burst_sram #(
        .SRAM_ADDR_WIDTH(8)
    ) dut (
        .clk(clk), .reset_n(reset_n),
        .s_awaddr(s_awaddr), .s_awlen(s_awlen),
        .s_awsize(s_awsize), .s_awburst(s_awburst),
        .s_awvalid(s_awvalid), .s_awready(s_awready),
        .s_wdata(s_wdata), .s_wstrb(s_wstrb),
        .s_wlast(s_wlast), .s_wvalid(s_wvalid),
        .s_wready(s_wready),
        .s_bresp(s_bresp), .s_bvalid(s_bvalid),
        .s_bready(s_bready),
        .s_araddr(s_araddr), .s_arlen(s_arlen),
        .s_arsize(s_arsize), .s_arburst(s_arburst),
        .s_arvalid(s_arvalid), .s_arready(s_arready),
        .s_rdata(s_rdata), .s_rresp(s_rresp),
        .s_rlast(s_rlast), .s_rvalid(s_rvalid),
        .s_rready(s_rready)
    );

    task automatic check;
        input condition;
        input string description;
        begin
            checks = checks + 1;
            if (condition !== 1'b1) begin
                errors = errors + 1;
                $display("[%0t] CHECK %0d FAIL: %s", $time,
                         checks, description);
            end
        end
    endtask

    task automatic reset_dut;
        begin
            @(negedge clk);
            reset_n = 1'b0;
            s_awvalid = 1'b0;
            s_wvalid = 1'b0;
            s_wlast = 1'b0;
            s_bready = 1'b0;
            s_arvalid = 1'b0;
            s_rready = 1'b0;
            repeat (3) @(posedge clk);
            check(s_awready == 1'b0 && s_arready == 1'b0 &&
                  s_wready == 1'b0 && s_bvalid == 1'b0 &&
                  s_rvalid == 1'b0,
                  "all AXI outputs are inactive while reset is asserted");
            @(negedge clk);
            reset_n = 1'b1;
            repeat (2) @(posedge clk);
            check(s_awready == 1'b1 && s_arready == 1'b1,
                  "slave returns idle after reset release");
        end
    endtask

    task automatic send_aw;
        input [31:0] address;
        input [7:0] length;
        input [2:0] size;
        input [1:0] burst;
        integer wait_cycles;
        begin
            @(negedge clk);
            s_awaddr = address;
            s_awlen = length;
            s_awsize = size;
            s_awburst = burst;
            s_awvalid = 1'b1;
            wait_cycles = 0;
            @(posedge clk);
            while (!(s_awvalid && s_awready)) begin
                wait_cycles = wait_cycles + 1;
                if (wait_cycles > 32)
                    $fatal(1, "Timeout waiting for AW handshake");
                @(posedge clk);
            end
            @(negedge clk);
            s_awvalid = 1'b0;
        end
    endtask

    task automatic send_w;
        input [31:0] data;
        input last;
        integer wait_cycles;
        begin
            @(negedge clk);
            s_wdata = data;
            s_wstrb = 4'b1111;
            s_wlast = last;
            s_wvalid = 1'b1;
            wait_cycles = 0;
            @(posedge clk);
            while (!(s_wvalid && s_wready)) begin
                wait_cycles = wait_cycles + 1;
                if (wait_cycles > 32)
                    $fatal(1, "Timeout waiting for W handshake");
                @(posedge clk);
            end
            @(negedge clk);
            s_wvalid = 1'b0;
            s_wlast = 1'b0;
        end
    endtask

    task automatic expect_b;
        input [1:0] expected_resp;
        integer wait_cycles;
        reg [1:0] held_resp;
        begin
            wait_cycles = 0;
            while (s_bvalid !== 1'b1) begin
                @(negedge clk);
                wait_cycles = wait_cycles + 1;
                if (wait_cycles > 32)
                    $fatal(1, "Timeout waiting for BVALID");
            end

            held_resp = s_bresp;
            repeat (2) begin
                @(posedge clk);
                check(s_bvalid == 1'b1 && s_bresp == held_resp,
                      "BVALID/BRESP remain stable while BREADY is low");
            end
            check(s_bresp == expected_resp, "BRESP matches expectation");

            @(negedge clk);
            s_bready = 1'b1;
            @(posedge clk);
            check(s_bvalid && s_bready, "B response handshakes once");
            b_count = b_count + 1;
            @(negedge clk);
            s_bready = 1'b0;
            #1;
            check(s_bvalid == 1'b0, "BVALID clears after handshake");
        end
    endtask

    // last_mode: 0=正确WLAST，1=第一拍提前WLAST且末拍也给WLAST，2=末拍不发WLAST。
    task automatic write_request;
        input [31:0] address;
        input [7:0] length;
        input [2:0] size;
        input [1:0] burst;
        input integer beat_count;
        input integer last_mode;
        input [1:0] expected_resp;
        input [31:0] data_base;
        integer beat_index;
        reg last_value;
        begin
            send_aw(address, length, size, burst);
            for (beat_index = 0; beat_index < beat_count;
                 beat_index = beat_index + 1) begin
                case (last_mode)
                    1: last_value = (beat_index == 0) ||
                                    (beat_index == beat_count - 1);
                    2: last_value = 1'b0;
                    default: last_value = (beat_index == beat_count - 1);
                endcase
                send_w(data_base + beat_index, last_value);
                if (beat_index != beat_count - 1)
                    check(s_bvalid == 1'b0,
                          "one B response is generated only after all expected W beats");
            end
            expect_b(expected_resp);
        end
    endtask

    task automatic send_ar;
        input [31:0] address;
        input [7:0] length;
        input [2:0] size;
        input [1:0] burst;
        integer wait_cycles;
        begin
            @(negedge clk);
            s_araddr = address;
            s_arlen = length;
            s_arsize = size;
            s_arburst = burst;
            s_arvalid = 1'b1;
            wait_cycles = 0;
            @(posedge clk);
            while (!(s_arvalid && s_arready)) begin
                wait_cycles = wait_cycles + 1;
                if (wait_cycles > 32)
                    $fatal(1, "Timeout waiting for AR handshake");
                @(posedge clk);
            end
            @(negedge clk);
            s_arvalid = 1'b0;
        end
    endtask

    task automatic expect_read_response;
        input integer beat_count;
        input [1:0] expected_resp;
        input integer expect_zero_data;
        integer beat_index;
        integer wait_cycles;
        reg [31:0] held_data;
        reg [1:0] held_resp;
        reg held_last;
        begin
            for (beat_index = 0; beat_index < beat_count;
                 beat_index = beat_index + 1) begin
                wait_cycles = 0;
                while (s_rvalid !== 1'b1) begin
                    @(negedge clk);
                    wait_cycles = wait_cycles + 1;
                    if (wait_cycles > 64)
                        $fatal(1, "Timeout waiting for RVALID beat %0d",
                               beat_index);
                end

                // 第一拍故意背压两周期，检查错误响应也必须稳定。
                if (beat_index == 0) begin
                    held_data = s_rdata;
                    held_resp = s_rresp;
                    held_last = s_rlast;
                    repeat (2) begin
                        @(posedge clk);
                        check(s_rvalid == 1'b1 &&
                              s_rdata == held_data &&
                              s_rresp == held_resp &&
                              s_rlast == held_last,
                              "R payload remains stable while RREADY is low");
                    end
                end

                check(s_rresp == expected_resp,
                      "RRESP matches expectation");
                check(s_rlast == (beat_index == beat_count - 1),
                      "RLAST appears only on the final response beat");
                if (expect_zero_data != 0)
                    check(s_rdata == 32'd0,
                          "invalid read returns zero data");

                @(negedge clk);
                s_rready = 1'b1;
                @(posedge clk);
                check(s_rvalid && s_rready, "R beat handshakes once");
                r_count = r_count + 1;
                if (expected_resp == RESP_OKAY)
                    read_value = s_rdata;
                @(negedge clk);
                s_rready = 1'b0;
            end
        end
    endtask

    task automatic invalid_read_request;
        input [31:0] address;
        input [7:0] length;
        input [2:0] size;
        input [1:0] burst;
        begin
            send_ar(address, length, size, burst);
            expect_read_response(length + 1, RESP_SLVERR, 1);
        end
    endtask

    task automatic legal_read_word;
        input [31:0] address;
        input [31:0] expected_data;
        begin
            send_ar(address, 8'd0, SIZE_4BYTE, BURST_INCR);
            expect_read_response(1, RESP_OKAY, 0);
            check(read_value == expected_data,
                  "legal read returns expected sentinel data");
        end
    endtask

    initial begin
        $display("============================================================");
        $display("AXI burst SRAM negative protocol and reset verification");
        $display("============================================================");

        reset_dut();

        // 建立哨兵数据，后续非法请求不得修改它。
        $display("[1] Establish sentinel word");
        write_request(32'h0000_0040, 8'd0, SIZE_4BYTE, BURST_INCR,
                      1, 0, RESP_OKAY, 32'ha5a5_5a5a);
        legal_read_word(32'h0000_0040, 32'ha5a5_5a5a);

        $display("[2] Misaligned AWADDR returns SLVERR and writes nothing");
        write_request(32'h0000_0041, 8'd0, SIZE_4BYTE, BURST_INCR,
                      1, 0, RESP_SLVERR, 32'h1111_0000);

        $display("[3] Illegal FIXED AWBURST returns SLVERR");
        write_request(32'h0000_0040, 8'd0, SIZE_4BYTE, BURST_FIXED,
                      1, 0, RESP_SLVERR, 32'h2222_0000);

        $display("[4] Narrow AWSIZE returns SLVERR");
        write_request(32'h0000_0040, 8'd0, SIZE_2BYTE, BURST_INCR,
                      1, 0, RESP_SLVERR, 32'h3333_0000);

        $display("[5] AWLEN=16 (17 beats) returns one SLVERR");
        write_request(32'h0000_0040, 8'd16, SIZE_4BYTE, BURST_INCR,
                      17, 0, RESP_SLVERR, 32'h4444_0000);

        $display("[6] Write crossing 4KiB returns SLVERR");
        write_request(32'h0000_0ffc, 8'd1, SIZE_4BYTE, BURST_INCR,
                      2, 0, RESP_SLVERR, 32'h5555_0000);

        legal_read_word(32'h0000_0040, 32'ha5a5_5a5a);

        $display("[7] Early WLAST drains remaining beats and returns SLVERR");
        write_request(32'h0000_0080, 8'd3, SIZE_4BYTE, BURST_INCR,
                      4, 1, RESP_SLVERR, 32'h7000_0000);

        $display("[8] Missing final WLAST returns SLVERR");
        write_request(32'h0000_00c0, 8'd3, SIZE_4BYTE, BURST_INCR,
                      4, 2, RESP_SLVERR, 32'h8000_0000);

        $display("[9] Misaligned ARADDR returns one SLVERR beat");
        invalid_read_request(32'h0000_0042, 8'd0,
                             SIZE_4BYTE, BURST_INCR);

        $display("[10] Illegal WRAP ARBURST returns four SLVERR beats");
        invalid_read_request(32'h0000_0040, 8'd3,
                             SIZE_4BYTE, BURST_WRAP);

        $display("[11] ARLEN=16 returns seventeen SLVERR beats");
        invalid_read_request(32'h0000_0040, 8'd16,
                             SIZE_4BYTE, BURST_INCR);

        $display("[12] Read crossing 4KiB returns two SLVERR beats");
        invalid_read_request(32'h0000_0ffc, 8'd1,
                             SIZE_4BYTE, BURST_INCR);

        $display("[13] Reset interrupts an active write, then slave recovers");
        send_aw(32'h0000_0100, 8'd3, SIZE_4BYTE, BURST_INCR);
        send_w(32'hdead_0001, 1'b0);
        @(negedge clk);
        reset_n = 1'b0;
        repeat (2) @(posedge clk);
        check(s_wready == 1'b0 && s_bvalid == 1'b0 &&
              s_awready == 1'b0,
              "write state and response clear immediately on reset");
        @(negedge clk);
        reset_n = 1'b1;
        repeat (2) @(posedge clk);
        check(s_awready == 1'b1 && s_arready == 1'b1,
              "slave accepts a new request after interrupted write reset");
        write_request(32'h0000_0140, 8'd0, SIZE_4BYTE, BURST_INCR,
                      1, 0, RESP_OKAY, 32'h1234_5678);
        legal_read_word(32'h0000_0140, 32'h1234_5678);

        $display("[14] Reset interrupts a stalled read, then slave recovers");
        write_request(32'h0000_0180, 8'd0, SIZE_4BYTE, BURST_INCR,
                      1, 0, RESP_OKAY, 32'h89ab_cdef);
        send_ar(32'h0000_0180, 8'd0, SIZE_4BYTE, BURST_INCR);
        while (s_rvalid !== 1'b1)
            @(negedge clk);
        check(s_rvalid == 1'b1 && s_rready == 1'b0,
              "read response is genuinely stalled before reset");
        @(negedge clk);
        reset_n = 1'b0;
        repeat (2) @(posedge clk);
        check(s_rvalid == 1'b0 && s_rlast == 1'b0 &&
              s_arready == 1'b0,
              "read response and state clear immediately on reset");
        @(negedge clk);
        reset_n = 1'b1;
        repeat (2) @(posedge clk);
        legal_read_word(32'h0000_0180, 32'h89ab_cdef);

        $display("------------------------------------------------------------");
        $display("Checks=%0d Errors=%0d B-responses=%0d R-beats=%0d",
                 checks, errors, b_count, r_count);
        if (errors == 0) begin
            $display("TEST PASS: AXI burst SRAM negative protocol cases");
            $finish;
        end
        $fatal(1, "TEST FAIL: AXI burst SRAM negative protocol errors=%0d",
               errors);
    end

    initial begin
        #200000;
        $fatal(1, "TEST FAIL: AXI burst SRAM negative-test timeout");
    end
endmodule
