`timescale 1ns/1ps

// 六通道 DMA AXI 寄存器从机独立验证。
// 验证 AXI 握手、六个 0x40 字节通道窗口、寄存器读回、背压和非法访问。
module tb_axi_dma6_reg_slave;
    localparam [31:0] DMA_BASE = 32'h4000_E000;
    localparam [1:0]  AXI_OKAY = 2'b00;
    localparam [1:0]  AXI_SLVERR = 2'b10;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg reset_n = 1'b0;

    reg  [31:0] s_awaddr = 32'd0;
    reg  [7:0]  s_awlen = 8'd0;
    reg  [2:0]  s_awsize = 3'b010;
    reg  [1:0]  s_awburst = 2'b01;
    reg         s_awvalid = 1'b0;
    wire        s_awready;

    reg  [31:0] s_wdata = 32'd0;
    reg  [3:0]  s_wstrb = 4'hF;
    reg         s_wlast = 1'b1;
    reg         s_wvalid = 1'b0;
    wire        s_wready;

    wire [1:0]  s_bresp;
    wire        s_bvalid;
    reg         s_bready = 1'b0;

    reg  [31:0] s_araddr = 32'd0;
    reg  [7:0]  s_arlen = 8'd0;
    reg  [2:0]  s_arsize = 3'b010;
    reg  [1:0]  s_arburst = 2'b01;
    reg         s_arvalid = 1'b0;
    wire        s_arready;

    wire [31:0] s_rdata;
    wire [1:0]  s_rresp;
    wire        s_rlast;
    wire        s_rvalid;
    reg         s_rready = 1'b0;

    wire        cfg_wr_en;
    wire [11:0] cfg_wr_offset;
    wire [31:0] cfg_wr_data;
    wire [11:0] cfg_rd_offset;
    wire [31:0] cfg_rd_data;

    wire [5:0]  channel_pending;
    wire [5:0]  channel_busy;
    wire [5:0]  channel_done;
    wire [5:0]  channel_error;
    wire [5:0]  irq;

    reg  [2:0]  scheduler_channel = 3'd0;
    wire [31:0] scheduler_src_addr;
    wire [31:0] scheduler_dst_addr;
    wire [15:0] scheduler_word_count;
    wire        scheduler_irq_enable;
    wire        scheduler_src_increment;
    wire        scheduler_dst_increment;
    wire        scheduler_fixed_burst_enable;
    wire        scheduler_enable;
    reg         scheduler_claim = 1'b0;
    reg         scheduler_complete = 1'b0;
    reg         scheduler_error = 1'b0;

    integer checks = 0;
    integer errors = 0;
    integer cfg_write_count = 0;
    integer ch;
    integer i;
    reg [31:0] read_value;
    reg [31:0] channel_base;

    axi_dma_reg_slave u_axi_slave (
        .clk(clk), .reset_n(reset_n),
        .s_awaddr(s_awaddr), .s_awlen(s_awlen),
        .s_awsize(s_awsize), .s_awburst(s_awburst),
        .s_awvalid(s_awvalid), .s_awready(s_awready),
        .s_wdata(s_wdata), .s_wstrb(s_wstrb),
        .s_wlast(s_wlast), .s_wvalid(s_wvalid),
        .s_wready(s_wready),
        .s_bresp(s_bresp), .s_bvalid(s_bvalid), .s_bready(s_bready),
        .s_araddr(s_araddr), .s_arlen(s_arlen),
        .s_arsize(s_arsize), .s_arburst(s_arburst),
        .s_arvalid(s_arvalid), .s_arready(s_arready),
        .s_rdata(s_rdata), .s_rresp(s_rresp),
        .s_rlast(s_rlast), .s_rvalid(s_rvalid), .s_rready(s_rready),
        .cfg_wr_en(cfg_wr_en), .cfg_wr_offset(cfg_wr_offset),
        .cfg_wr_data(cfg_wr_data), .cfg_rd_offset(cfg_rd_offset),
        .cfg_rd_data(cfg_rd_data)
    );

    dma6_register_file u_register_file (
        .clk(clk), .reset_n(reset_n),
        .wr_en(cfg_wr_en), .wr_offset(cfg_wr_offset),
        .wr_data(cfg_wr_data), .rd_offset(cfg_rd_offset),
        .rd_data(cfg_rd_data),
        .channel_pending(channel_pending),
        .channel_busy(channel_busy),
        .channel_done(channel_done),
        .channel_error(channel_error),
        .scheduler_channel(scheduler_channel),
        .scheduler_src_addr(scheduler_src_addr),
        .scheduler_dst_addr(scheduler_dst_addr),
        .scheduler_word_count(scheduler_word_count),
        .scheduler_irq_enable(scheduler_irq_enable),
        .scheduler_src_increment(scheduler_src_increment),
        .scheduler_dst_increment(scheduler_dst_increment),
        .scheduler_fixed_burst_enable(scheduler_fixed_burst_enable),
        .scheduler_claim(scheduler_claim),
        .scheduler_complete(scheduler_complete),
        .scheduler_error(scheduler_error),
        .scheduler_enable(scheduler_enable),
        .irq(irq)
    );

    always @(posedge clk) begin
        if (cfg_wr_en)
            cfg_write_count <= cfg_write_count + 1;
    end

    task automatic check;
        input condition;
        input [8*96-1:0] message;
        begin
            checks = checks + 1;
            if (!condition) begin
                errors = errors + 1;
                $display("[%0t] CHECK %0d FAIL: %0s", $time, checks, message);
            end else begin
                $display("[%0t] CHECK %0d PASS: %0s", $time, checks, message);
            end
        end
    endtask

    task automatic send_aw;
        input [31:0] address;
        input [7:0] length;
        begin
            @(negedge clk);
            s_awaddr = address;
            s_awlen = length;
            s_awvalid = 1'b1;
            while (!(s_awvalid && s_awready))
                @(posedge clk);
            @(negedge clk);
            s_awvalid = 1'b0;
        end
    endtask

    task automatic send_w;
        input [31:0] data;
        input [3:0] strobe;
        input last;
        begin
            @(negedge clk);
            s_wdata = data;
            s_wstrb = strobe;
            s_wlast = last;
            s_wvalid = 1'b1;
            while (!(s_wvalid && s_wready))
                @(posedge clk);
            @(negedge clk);
            s_wvalid = 1'b0;
        end
    endtask

    task automatic expect_b;
        input [1:0] expected_response;
        begin
            // 故意保持 BREADY=0，检查响应在阻塞期间不会消失。
            repeat (2) @(negedge clk);
            check(s_bvalid && (s_bresp === expected_response),
                  "BVALID/BRESP stable while BREADY is low");
            s_bready = 1'b1;
            @(posedge clk);
            check(s_bvalid && (s_bresp === expected_response),
                  "B response handshake");
            @(negedge clk);
            s_bready = 1'b0;
            check(!s_bvalid, "exactly one B response");
        end
    endtask

    task automatic axi_write_aw_first;
        input [31:0] address;
        input [31:0] data;
        input [1:0] expected_response;
        begin
            send_aw(address, 8'd0);
            repeat (2) @(negedge clk);
            send_w(data, 4'hF, 1'b1);
            expect_b(expected_response);
        end
    endtask

    task automatic axi_write_w_first;
        input [31:0] address;
        input [31:0] data;
        input [1:0] expected_response;
        begin
            send_w(data, 4'hF, 1'b1);
            repeat (2) @(negedge clk);
            send_aw(address, 8'd0);
            expect_b(expected_response);
        end
    endtask

    task automatic send_ar;
        input [31:0] address;
        input [7:0] length;
        begin
            @(negedge clk);
            s_araddr = address;
            s_arlen = length;
            s_arvalid = 1'b1;
            while (!(s_arvalid && s_arready))
                @(posedge clk);
            @(negedge clk);
            s_arvalid = 1'b0;
        end
    endtask

    task automatic axi_read_one;
        input [31:0] address;
        input [31:0] expected_data;
        input [1:0] expected_response;
        begin
            send_ar(address, 8'd0);

            // 故意保持 RREADY=0，检查数据在阻塞期间保持稳定。
            repeat (2) @(negedge clk);
            check(s_rvalid && (s_rdata === expected_data) &&
                  (s_rresp === expected_response) && s_rlast,
                  "R channel payload stable while RREADY is low");
            read_value = s_rdata;
            s_rready = 1'b1;
            @(posedge clk);
            check(s_rvalid && (s_rdata === expected_data) &&
                  (s_rresp === expected_response) && s_rlast,
                  "single-beat R handshake");
            @(negedge clk);
            s_rready = 1'b0;
            check(!s_rvalid, "exactly one R beat");
        end
    endtask

    initial begin
        #50000;
        $fatal(1, "TEST FAIL: AXI DMA6 register-slave simulation timeout");
    end

    initial begin
        $display("============================================================");
        $display("Starting six-channel AXI DMA register-slave simulation");
        $display("============================================================");

        repeat (5) @(negedge clk);
        reset_n = 1'b1;

        // -------------------------------------------------------------
        // 六个通道全部执行写入和读回。奇偶通道故意交换 AW/W 到达顺序。
        // -------------------------------------------------------------
        for (ch = 0; ch < 6; ch = ch + 1) begin
            channel_base = DMA_BASE + ch * 32'h40;
            $display("\nTEST channel %0d register window @ 0x%08x",
                     ch, channel_base);

            if ((ch & 1) == 0) begin
                axi_write_aw_first(channel_base + 32'h00,
                                   32'h2000_0000 + ch * 32'h100,
                                   AXI_OKAY);
                axi_write_w_first(channel_base + 32'h04,
                                  32'h2000_8000 + ch * 32'h100,
                                  AXI_OKAY);
            end else begin
                axi_write_w_first(channel_base + 32'h00,
                                  32'h2000_0000 + ch * 32'h100,
                                  AXI_OKAY);
                axi_write_aw_first(channel_base + 32'h04,
                                   32'h2000_8000 + ch * 32'h100,
                                   AXI_OKAY);
            end

            axi_write_aw_first(channel_base + 32'h08, ch + 32'd1,
                               AXI_OKAY);
            // START=0, IRQ_EN=1, SRC_INC=1, DST_INC=1。
            axi_write_aw_first(channel_base + 32'h0C, 32'h0000_000E,
                               AXI_OKAY);

            axi_read_one(channel_base + 32'h00,
                         32'h2000_0000 + ch * 32'h100, AXI_OKAY);
            axi_read_one(channel_base + 32'h04,
                         32'h2000_8000 + ch * 32'h100, AXI_OKAY);
            axi_read_one(channel_base + 32'h08, ch + 32'd1, AXI_OKAY);
            axi_read_one(channel_base + 32'h0C, 32'h0000_000E, AXI_OKAY);
            axi_read_one(channel_base + 32'h10, 32'd0, AXI_OKAY);
            axi_read_one(channel_base + 32'h14, 32'd0, AXI_OKAY);
            axi_read_one(channel_base + 32'h18, 32'd0, AXI_OKAY);
            axi_read_one(channel_base + 32'h1C, 32'd0, AXI_OKAY);
        end

        // STATUS 是可写的 W1C 寄存器，验证通道5的最高合法窗口。
        axi_write_aw_first(DMA_BASE + 32'h150, 32'h0000_000C, AXI_OKAY);
        check(cfg_write_count == 25,
              "24 configuration writes plus one STATUS W1C write committed");

        // -------------------------------------------------------------
        // 全局控制和六通道聚合状态寄存器。
        // -------------------------------------------------------------
        $display("\nTEST global scheduler and status registers");
        axi_read_one(DMA_BASE + 32'h180, 32'h0000_0001, AXI_OKAY);
        axi_write_aw_first(DMA_BASE + 32'h180, 32'h0000_0000, AXI_OKAY);
        axi_read_one(DMA_BASE + 32'h180, 32'h0000_0000, AXI_OKAY);
        axi_read_one(DMA_BASE + 32'h184, 32'h0000_0000, AXI_OKAY);
        axi_read_one(DMA_BASE + 32'h188, 32'h0000_0000, AXI_OKAY);
        axi_read_one(DMA_BASE + 32'h18C, 32'h0000_0000, AXI_OKAY);
        axi_read_one(DMA_BASE + 32'h190, 32'h0000_0000, AXI_OKAY);
        axi_write_aw_first(DMA_BASE + 32'h180, 32'h0000_0001, AXI_OKAY);
        axi_read_one(DMA_BASE + 32'h180, 32'h0000_0001, AXI_OKAY);
        check(cfg_write_count == 27,
              "two global control writes reached the local register file");

        // -------------------------------------------------------------
        // 非法通道、窗口空洞、越界页面和非对齐访问必须返回 SLVERR。
        // -------------------------------------------------------------
        $display("\nTEST invalid register addresses");
        axi_write_aw_first(DMA_BASE + 32'h194, 32'hDEAD_BEEF, AXI_SLVERR);
        axi_write_aw_first(DMA_BASE + 32'h020, 32'hDEAD_BEEF, AXI_SLVERR);
        axi_write_aw_first(32'h4000_F000, 32'hDEAD_BEEF, AXI_SLVERR);
        axi_write_aw_first(DMA_BASE + 32'h001, 32'hDEAD_BEEF, AXI_SLVERR);
        check(cfg_write_count == 27,
              "invalid writes generated no local register write pulse");

        axi_read_one(DMA_BASE + 32'h194, 32'd0, AXI_SLVERR);
        axi_read_one(DMA_BASE + 32'h020, 32'd0, AXI_SLVERR);
        axi_read_one(32'h4000_F000, 32'd0, AXI_SLVERR);

        // 部分字节写不允许修改寄存器。
        send_aw(DMA_BASE + 32'h000, 8'd0);
        send_w(32'hFFFF_FFFF, 4'b0001, 1'b1);
        expect_b(AXI_SLVERR);
        axi_read_one(DMA_BASE + 32'h000, 32'h2000_0000, AXI_OKAY);
        check(cfg_write_count == 27,
              "partial WSTRB generated no local register write pulse");

        // -------------------------------------------------------------
        // 寄存器页只支持单拍。非法写Burst必须排空到WLAST后响应一次错误；
        // 非法读Burst必须返回ARLEN+1个错误拍并在最后一拍给出RLAST。
        // -------------------------------------------------------------
        $display("\nTEST unsupported bursts");
        send_aw(DMA_BASE + 32'h000, 8'd3);
        for (i = 0; i < 4; i = i + 1)
            send_w(32'hA500_0000 + i, 4'hF, i == 3);
        expect_b(AXI_SLVERR);
        check(cfg_write_count == 27,
              "unsupported write burst generated no register write pulse");

        send_ar(DMA_BASE + 32'h000, 8'd3);
        repeat (2) @(negedge clk);
        check(s_rvalid && (s_rresp == AXI_SLVERR) && !s_rlast,
              "unsupported read burst starts with SLVERR");
        s_rready = 1'b1;
        for (i = 0; i < 4; i = i + 1) begin
            @(posedge clk);
            check(s_rvalid && (s_rdata == 32'd0) &&
                  (s_rresp == AXI_SLVERR) && (s_rlast == (i == 3)),
                  "unsupported read burst beat and RLAST are correct");
        end
        @(negedge clk);
        s_rready = 1'b0;
        check(!s_rvalid, "unsupported read burst ends after four beats");

        check(channel_pending == 6'b000000,
              "configuration without START creates no pending task");
        check(channel_busy == 6'b000000,
              "no channel is busy in register-only test");
        check(channel_error == 6'b000000,
              "AXI address errors do not corrupt DMA channel state");

        $display("\n============================================================");
        $display("Checks : %0d", checks);
        $display("Errors : %0d", errors);
        if (errors == 0)
            $display("TEST PASS: six-channel AXI DMA register slave works");
        else begin
            $display("TEST FAIL: %0d error(s)", errors);
            $fatal(1, "six-channel AXI DMA register-slave verification failed");
        end
        $display("============================================================");
        $finish;
    end
endmodule
