`timescale 1ns/1ps

// 六通道DMA混合Burst自检：
//   1. 通道0执行16 word SRAM(INCR) -> FIFO(FIXED)；
//   2. 通道1执行16 word FIFO(FIXED) -> SRAM(INCR)；
//   3. 通道2执行SRAM Burst读，再把数据拆成多次UART单拍写；
//   4. 通道3执行多次UART单拍读，再合并成一次SRAM Burst写。
// 测试通过本地寄存器接口配置dma6_core，因此同时覆盖寄存器文件、
// 轮询调度器、dma_carry以及新增的CONTROL[4]信号链。
module tb_dma6_mixed_burst_16;
    localparam [1:0] AXI_BURST_FIXED = 2'b00;
    localparam [1:0] AXI_BURST_INCR  = 2'b01;
    localparam [1:0] AXI_RESP_OKAY   = 2'b00;

    localparam [31:0] CTRL_START       = 32'h0000_0001;
    localparam [31:0] CTRL_SRC_INC     = 32'h0000_0004;
    localparam [31:0] CTRL_DST_INC     = 32'h0000_0008;
    localparam [31:0] CTRL_FIXED_BURST = 32'h0000_0010;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg reset_n = 1'b0;

    reg         wr_en = 1'b0;
    reg  [11:0] wr_offset = 12'd0;
    reg  [31:0] wr_data = 32'd0;
    reg  [11:0] rd_offset = 12'd0;
    wire [31:0] rd_data;

    wire [5:0] channel_pending;
    wire [5:0] channel_busy;
    wire [5:0] channel_done;
    wire [5:0] channel_error;
    wire [5:0] irq;

    wire [31:0] m_araddr;
    wire [7:0]  m_arlen;
    wire [2:0]  m_arsize;
    wire [1:0]  m_arburst;
    wire        m_arvalid;
    reg         m_arready = 1'b0;

    reg  [31:0] m_rdata = 32'd0;
    reg  [1:0]  m_rresp = AXI_RESP_OKAY;
    reg         m_rlast = 1'b0;
    reg         m_rvalid = 1'b0;
    wire        m_rready;

    wire [31:0] m_awaddr;
    wire [7:0]  m_awlen;
    wire [2:0]  m_awsize;
    wire [1:0]  m_awburst;
    wire        m_awvalid;
    reg         m_awready = 1'b0;

    wire [31:0] m_wdata;
    wire [3:0]  m_wstrb;
    wire        m_wlast;
    wire        m_wvalid;
    reg         m_wready = 1'b0;

    reg  [1:0]  m_bresp = AXI_RESP_OKAY;
    reg         m_bvalid = 1'b0;
    wire        m_bready;

    integer checks = 0;
    integer ar_count = 0;
    integer r_count = 0;
    integer aw_count = 0;
    integer w_count = 0;
    integer b_count = 0;

    dma6_core dut (
        .clk(clk),
        .reset_n(reset_n),
        .wr_en(wr_en),
        .wr_offset(wr_offset),
        .wr_data(wr_data),
        .rd_offset(rd_offset),
        .rd_data(rd_data),
        .channel_pending(channel_pending),
        .channel_busy(channel_busy),
        .channel_done(channel_done),
        .channel_error(channel_error),
        .irq(irq),
        .m_araddr(m_araddr),
        .m_arlen(m_arlen),
        .m_arsize(m_arsize),
        .m_arburst(m_arburst),
        .m_arvalid(m_arvalid),
        .m_arready(m_arready),
        .m_rdata(m_rdata),
        .m_rresp(m_rresp),
        .m_rlast(m_rlast),
        .m_rvalid(m_rvalid),
        .m_rready(m_rready),
        .m_awaddr(m_awaddr),
        .m_awlen(m_awlen),
        .m_awsize(m_awsize),
        .m_awburst(m_awburst),
        .m_awvalid(m_awvalid),
        .m_awready(m_awready),
        .m_wdata(m_wdata),
        .m_wstrb(m_wstrb),
        .m_wlast(m_wlast),
        .m_wvalid(m_wvalid),
        .m_wready(m_wready),
        .m_bresp(m_bresp),
        .m_bvalid(m_bvalid),
        .m_bready(m_bready)
    );

    always @(posedge clk) begin
        if (reset_n) begin
            if (m_arvalid && m_arready)
                ar_count = ar_count + 1;
            if (m_rvalid && m_rready)
                r_count = r_count + 1;
            if (m_awvalid && m_awready)
                aw_count = aw_count + 1;
            if (m_wvalid && m_wready)
                w_count = w_count + 1;
            if (m_bvalid && m_bready)
                b_count = b_count + 1;
        end
    end

    task automatic check(input bit condition, input string description);
        begin
            checks = checks + 1;
            if (!condition)
                $fatal(1, "CHECK %0d FAIL: %s at %0t", checks,
                       description, $time);
        end
    endtask

    task automatic register_write(
        input [11:0] offset,
        input [31:0] value
    );
        begin
            @(negedge clk);
            wr_offset = offset;
            wr_data = value;
            wr_en = 1'b1;
            @(posedge clk);
            @(negedge clk);
            wr_en = 1'b0;
            wr_offset = 12'd0;
            wr_data = 32'd0;
        end
    endtask

    task automatic register_read(
        input [11:0] offset,
        output [31:0] value
    );
        begin
            @(negedge clk);
            rd_offset = offset;
            #1 value = rd_data;
        end
    endtask

    // 模拟软件的两步流程：先配置并读回CONTROL，再单独写START。
    task automatic configure_and_start(
        input integer channel,
        input [31:0] source_address,
        input [31:0] destination_address,
        input [15:0] words,
        input [31:0] control_options
    );
        reg [11:0] base;
        reg [31:0] control_readback;
        begin
            base = channel * 12'h040;
            register_write(base + 12'h000, source_address);
            register_write(base + 12'h004, destination_address);
            register_write(base + 12'h008, {16'd0, words});
            register_write(base + 12'h00c, control_options);
            register_read(base + 12'h00c, control_readback);
            check((control_readback & 32'h0000_001e) ==
                  (control_options & 32'h0000_001e),
                  "CONTROL options, including FIXED_BURST, read back");
            register_write(base + 12'h00c,
                           control_readback | CTRL_START);
        end
    endtask

    task automatic accept_ar(
        input [31:0] expected_addr,
        input [7:0] expected_len,
        input [1:0] expected_burst
    );
        reg [31:0] held_addr;
        reg [7:0] held_len;
        reg [2:0] held_size;
        reg [1:0] held_burst;
        integer hold_cycle;
        begin
            while (!m_arvalid)
                @(posedge clk);
            @(negedge clk);
            held_addr = m_araddr;
            held_len = m_arlen;
            held_size = m_arsize;
            held_burst = m_arburst;
            check(held_addr == expected_addr, "ARADDR is correct");
            check(held_len == expected_len, "ARLEN is correct");
            check(held_size == 3'b010, "ARSIZE is four bytes");
            check(held_burst == expected_burst, "ARBURST is correct");

            // 故意阻塞ARREADY，检查VALID和全部地址属性保持稳定。
            for (hold_cycle = 0; hold_cycle < 3; hold_cycle = hold_cycle + 1) begin
                @(posedge clk);
                #1;
                check(m_arvalid, "ARVALID stays high while blocked");
                check(m_araddr == held_addr && m_arlen == held_len &&
                      m_arsize == held_size && m_arburst == held_burst,
                      "AR payload stays stable while blocked");
            end

            @(negedge clk);
            m_arready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            m_arready = 1'b0;
        end
    endtask

    task automatic send_r_burst(
        input integer beat_count,
        input [31:0] data_base
    );
        integer beat;
        begin
            for (beat = 0; beat < beat_count; beat = beat + 1) begin
                // 制造R通道空拍，证明DMA能等待从设备。
                if ((beat % 3) == 1)
                    @(posedge clk);
                @(negedge clk);
                m_rdata = data_base + beat;
                m_rresp = AXI_RESP_OKAY;
                m_rlast = (beat == beat_count - 1);
                m_rvalid = 1'b1;
                check(m_rready, "DMA is ready for declared R burst");
                @(posedge clk);
                @(negedge clk);
                m_rvalid = 1'b0;
                m_rlast = 1'b0;
            end
        end
    endtask

    task automatic accept_aw(
        input [31:0] expected_addr,
        input [7:0] expected_len,
        input [1:0] expected_burst
    );
        reg [31:0] held_addr;
        reg [7:0] held_len;
        reg [2:0] held_size;
        reg [1:0] held_burst;
        integer hold_cycle;
        begin
            while (!m_awvalid)
                @(posedge clk);
            @(negedge clk);
            held_addr = m_awaddr;
            held_len = m_awlen;
            held_size = m_awsize;
            held_burst = m_awburst;
            check(held_addr == expected_addr, "AWADDR is correct");
            check(held_len == expected_len, "AWLEN is correct");
            check(held_size == 3'b010, "AWSIZE is four bytes");
            check(held_burst == expected_burst, "AWBURST is correct");

            // 故意阻塞AWREADY，检查VALID和地址属性保持稳定。
            for (hold_cycle = 0; hold_cycle < 2; hold_cycle = hold_cycle + 1) begin
                @(posedge clk);
                #1;
                check(m_awvalid, "AWVALID stays high while blocked");
                check(m_awaddr == held_addr && m_awlen == held_len &&
                      m_awsize == held_size && m_awburst == held_burst,
                      "AW payload stays stable while blocked");
            end

            @(negedge clk);
            m_awready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            m_awready = 1'b0;
        end
    endtask

    task automatic receive_w_burst(
        input integer beat_count,
        input [31:0] expected_base
    );
        integer beat;
        integer stall_cycle;
        reg [31:0] held_data;
        reg held_last;
        begin
            for (beat = 0; beat < beat_count; beat = beat + 1) begin
                while (!m_wvalid)
                    @(negedge clk);
                check(m_wdata == expected_base + beat,
                      "WDATA preserves R beat order");
                check(m_wstrb == 4'b1111, "WSTRB writes all byte lanes");
                check(m_wlast == (beat == beat_count - 1),
                      "WLAST appears only on final beat");

                // 每四拍制造两周期W背压，检查数据和LAST保持稳定。
                if ((beat % 4) == 2) begin
                    held_data = m_wdata;
                    held_last = m_wlast;
                    for (stall_cycle = 0; stall_cycle < 2;
                         stall_cycle = stall_cycle + 1) begin
                        @(posedge clk);
                        #1;
                        check(m_wvalid, "WVALID stays high while blocked");
                        check(m_wdata == held_data && m_wlast == held_last &&
                              m_wstrb == 4'b1111,
                              "W payload stays stable while blocked");
                    end
                end

                @(negedge clk);
                m_wready = 1'b1;
                @(posedge clk);
                @(negedge clk);
                m_wready = 1'b0;
            end
        end
    endtask

    task automatic send_b_okay;
        begin
            // 一个写Burst只返回一个B响应，并故意延迟该响应。
            repeat (3) @(posedge clk);
            @(negedge clk);
            m_bresp = AXI_RESP_OKAY;
            m_bvalid = 1'b1;
            check(m_bready, "DMA waits for the B response");
            @(posedge clk);
            @(negedge clk);
            m_bvalid = 1'b0;
        end
    endtask

    task automatic wait_channel_done(input integer channel);
        integer timeout_cycles;
        begin
            timeout_cycles = 0;
            while (!channel_done[channel] && timeout_cycles < 100) begin
                @(posedge clk);
                timeout_cycles = timeout_cycles + 1;
            end
            check(channel_done[channel], "channel reaches DONE");
            check(!channel_error[channel], "channel completes without ERROR");
            check(!channel_busy[channel] && !channel_pending[channel],
                  "channel is no longer BUSY or PENDING");
        end
    endtask

    integer ar_before;
    integer r_before;
    integer aw_before;
    integer w_before;
    integer b_before;
    integer segment;

    initial begin
        $display("============================================================");
        $display("Starting DMA 16-beat mixed FIXED/INCR Burst verification");
        $display("============================================================");

        repeat (6) @(posedge clk);
        @(negedge clk);
        reset_n = 1'b1;

        // -------------------------------------------------------------
        // TEST 1: 16拍 INCR读 + 16拍 FIXED写。
        // -------------------------------------------------------------
        $display("TEST 1: channel0 SRAM(INCR) -> FIFO(FIXED), 16 beats");
        ar_before = ar_count;
        r_before = r_count;
        aw_before = aw_count;
        w_before = w_count;
        b_before = b_count;

        configure_and_start(0, 32'h2000_0200, 32'h4000_1000, 16,
                            CTRL_SRC_INC | CTRL_FIXED_BURST);
        accept_ar(32'h2000_0200, 8'd15, AXI_BURST_INCR);
        send_r_burst(16, 32'ha500_0000);
        accept_aw(32'h4000_1000, 8'd15, AXI_BURST_FIXED);
        receive_w_burst(16, 32'ha500_0000);
        send_b_okay();
        wait_channel_done(0);

        check(ar_count - ar_before == 1, "TEST1 has one AR transaction");
        check(r_count - r_before == 16, "TEST1 transfers sixteen R beats");
        check(aw_count - aw_before == 1, "TEST1 has one AW transaction");
        check(w_count - w_before == 16, "TEST1 transfers sixteen W beats");
        check(b_count - b_before == 1, "TEST1 has one B response");

        // -------------------------------------------------------------
        // TEST 2: 16拍 FIXED读 + 16拍 INCR写。
        // -------------------------------------------------------------
        $display("TEST 2: channel1 FIFO(FIXED) -> SRAM(INCR), 16 beats");
        ar_before = ar_count;
        r_before = r_count;
        aw_before = aw_count;
        w_before = w_count;
        b_before = b_count;

        configure_and_start(1, 32'h4000_1000, 32'h2000_0400, 16,
                            CTRL_DST_INC | CTRL_FIXED_BURST);
        accept_ar(32'h4000_1000, 8'd15, AXI_BURST_FIXED);
        send_r_burst(16, 32'hb600_0000);
        accept_aw(32'h2000_0400, 8'd15, AXI_BURST_INCR);
        receive_w_burst(16, 32'hb600_0000);
        send_b_okay();
        wait_channel_done(1);

        check(ar_count - ar_before == 1, "TEST2 has one AR transaction");
        check(r_count - r_before == 16, "TEST2 transfers sixteen R beats");
        check(aw_count - aw_before == 1, "TEST2 has one AW transaction");
        check(w_count - w_before == 16, "TEST2 transfers sixteen W beats");
        check(b_count - b_before == 1, "TEST2 has one B response");

        // -------------------------------------------------------------
        // TEST 3: SRAM -> UART。
        // SRAM一侧允许INCR Burst；UART/APB一侧必须拆成单拍。
        // -------------------------------------------------------------
        $display("TEST 3: SRAM burst read -> UART single-beat writes");
        ar_before = ar_count;
        r_before = r_count;
        aw_before = aw_count;
        w_before = w_count;
        b_before = b_count;

        configure_and_start(2, 32'h2000_0600, 32'h4000_4000, 4,
                            CTRL_SRC_INC);
        accept_ar(32'h2000_0600, 8'd3, AXI_BURST_INCR);
        send_r_burst(4, 32'hc700_0000);
        for (segment = 0; segment < 4; segment = segment + 1) begin
            accept_aw(32'h4000_4000, 8'd0, AXI_BURST_INCR);
            receive_w_burst(1, 32'hc700_0000 + segment);
            send_b_okay();
        end
        wait_channel_done(2);

        check(ar_count - ar_before == 1, "SRAM source uses one AR burst");
        check(r_count - r_before == 4, "SRAM source returns four R beats");
        check(aw_count - aw_before == 4, "UART destination uses four single AWs");
        check(w_count - w_before == 4, "UART destination receives four W beats");
        check(b_count - b_before == 4, "UART destination returns four B responses");

        // -------------------------------------------------------------
        // TEST 4: UART -> SRAM。
        // UART/APB一侧必须逐字单拍读；SRAM一侧合并成INCR Burst。
        // -------------------------------------------------------------
        $display("TEST 4: UART single-beat reads -> SRAM burst write");
        ar_before = ar_count;
        r_before = r_count;
        aw_before = aw_count;
        w_before = w_count;
        b_before = b_count;

        configure_and_start(3, 32'h4000_4004, 32'h2000_0800, 4,
                            CTRL_DST_INC);
        for (segment = 0; segment < 4; segment = segment + 1) begin
            accept_ar(32'h4000_4004, 8'd0, AXI_BURST_INCR);
            send_r_burst(1, 32'hd800_0000 + segment);
        end
        accept_aw(32'h2000_0800, 8'd3, AXI_BURST_INCR);
        receive_w_burst(4, 32'hd800_0000);
        send_b_okay();
        wait_channel_done(3);

        check(ar_count - ar_before == 4, "UART source uses four single ARs");
        check(r_count - r_before == 4, "UART source returns four R beats");
        check(aw_count - aw_before == 1, "SRAM destination uses one AW burst");
        check(w_count - w_before == 4, "SRAM destination receives four W beats");
        check(b_count - b_before == 1, "SRAM destination returns one B response");

        check(channel_error == 6'b00_0000, "no DMA channel reports error");
        check(irq == 6'b00_0000, "IRQs stay low because IRQ_EN was not set");

        $display("------------------------------------------------------------");
        $display("AR=%0d R=%0d AW=%0d W=%0d B=%0d", ar_count, r_count,
                 aw_count, w_count, b_count);
        $display("TEST PASS: DMA mixed Burst and UART beat conversion are correct");
        $display("Checks: %0d", checks);
        $display("============================================================");
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "TEST FAIL: DMA mixed Burst simulation timeout");
    end
endmodule
