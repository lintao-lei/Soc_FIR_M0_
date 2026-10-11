`timescale 1ns/1ps

// Cortex-M0一次提交六个DMA通道的完整系统场景。
// 重点证明：六个PENDING可同时存在，但单搬运引擎仍逐通道执行。
module tb_soc_top_cpu_dma6_scenario;
    localparam integer CPB = 434;
    localparam integer WORD_COUNT = 16;
    localparam integer MAX_CYCLES = 500000;

    localparam integer MAILBOX_WORD   = (32'h1000 >> 2);
    localparam [31:0] FIR_INPUT_BASE  = 32'h2000_1200;
    localparam [31:0] FIR_OUTPUT_BASE = 32'h2000_1400;
    localparam [31:0] UART_TX_BASE    = 32'h2000_1600;
    localparam [31:0] UART_RX_BASE    = 32'h2000_1700;
    localparam [31:0] COPY4_SRC_BASE  = 32'h2000_1800;
    localparam [31:0] COPY4_DST_BASE  = 32'h2000_1900;
    localparam [31:0] COPY5_SRC_BASE  = 32'h2000_1a00;
    localparam [31:0] COPY5_DST_BASE  = 32'h2000_1b00;
    localparam [31:0] FIR_DATA_ADDR   = 32'h4000_1000;
    localparam [31:0] UART_TX_ADDR    = 32'h4000_4000;
    localparam [31:0] UART_RX_ADDR    = 32'h4000_4004;

    localparam [31:0] ST_ALL_PENDING  = 32'h0000_0610;
    localparam [31:0] ST_RUNNING      = 32'h0000_0620;
    localparam [31:0] ST_ALL_DONE     = 32'h0000_0630;
    localparam [31:0] ST_FAILED       = 32'h0000_06ff;
    localparam [31:0] PASS_SIGNATURE  = 32'h5041_5353;
    localparam [31:0] FAIL_SIGNATURE  = 32'h4641_494c;
    localparam [31:0] HOST_READY      = 32'h484f_5354;
    localparam [31:0] GUARD_VALUE     = 32'hcafe_f00d;

    reg clk_board = 1'b0;
    always #10 clk_board = ~clk_board;

    reg reset_n = 1'b0;
    reg uart_rx = 1'b1;
    wire uart_tx;
    wire led_run;
    wire led_error;

    integer checks = 0;
    integer cycles = 0;
    integer claim_count = 0;
    integer expected_claim = 0;
    integer dma_ar_count = 0;
    integer dma_r_count = 0;
    integer dma_aw_count = 0;
    integer dma_w_count = 0;
    integer dma_b_count = 0;
    integer ar_beat = 0;
    integer aw_beat = 0;
    integer active_arlen = 0;
    integer active_awlen = 0;
    integer cpu_irq_status_reads = 0;
    integer response_errors = 0;
    integer tx_serial_count = 0;
    integer serial_errors = 0;
    integer index;
    integer waited;
    reg all_pending_seen = 1'b0;
    reg [5:0] irq_seen = 6'd0;
    reg [7:0] tx_serial_bytes [0:WORD_COUNT-1];
    reg [8*512-1:0] firmware_path;

    soc_top dut (
        .clk_board (clk_board),
        .reset_n   (reset_n),
        .uart_rx   (uart_rx),
        .uart_tx   (uart_tx),
        .led_run   (led_run),
        .led_error (led_error)
    );

    wire [31:0] fw_stage =
        dut.u_fabric.u_axi_interconnect.u_two_sram.u_data_sram
           .u_simple_sram_core.memory[MAILBOX_WORD + 0];
    wire [31:0] fw_signature =
        dut.u_fabric.u_axi_interconnect.u_two_sram.u_data_sram
           .u_simple_sram_core.memory[MAILBOX_WORD + 1];
    wire [31:0] fw_failure =
        dut.u_fabric.u_axi_interconnect.u_two_sram.u_data_sram
           .u_simple_sram_core.memory[MAILBOX_WORD + 2];
    wire [31:0] fw_pending =
        dut.u_fabric.u_axi_interconnect.u_two_sram.u_data_sram
           .u_simple_sram_core.memory[MAILBOX_WORD + 4];
    wire [31:0] fw_busy =
        dut.u_fabric.u_axi_interconnect.u_two_sram.u_data_sram
           .u_simple_sram_core.memory[MAILBOX_WORD + 5];
    wire [31:0] fw_done =
        dut.u_fabric.u_axi_interconnect.u_two_sram.u_data_sram
           .u_simple_sram_core.memory[MAILBOX_WORD + 6];
    wire [31:0] fw_error =
        dut.u_fabric.u_axi_interconnect.u_two_sram.u_data_sram
           .u_simple_sram_core.memory[MAILBOX_WORD + 7];
    wire [31:0] fw_fir_status =
        dut.u_fabric.u_axi_interconnect.u_two_sram.u_data_sram
           .u_simple_sram_core.memory[MAILBOX_WORD + 8];
    wire [31:0] fw_irq_done_events =
        dut.u_fabric.u_axi_interconnect.u_two_sram.u_data_sram
           .u_simple_sram_core.memory[MAILBOX_WORD + 9];
    wire [31:0] fw_irq_error_events =
        dut.u_fabric.u_axi_interconnect.u_two_sram.u_data_sram
           .u_simple_sram_core.memory[MAILBOX_WORD + 10];

    function automatic signed [31:0] expected_fir_output;
        input integer sample_index;
        integer signed sample;
        integer signed product;
        integer signed magnitude;
        integer signed rounded;
        begin
            sample = sample_index * 257 - 1928;
            product = sample * 32767;
            if (product < 0) begin
                magnitude = -product;
                rounded = -((magnitude + 16384) >>> 15);
            end else begin
                rounded = (product + 16384) >>> 15;
            end
            expected_fir_output = rounded;
        end
    endfunction

    task automatic check;
        input condition;
        input string description;
        begin
            checks = checks + 1;
            if (!condition)
                $fatal(1, "CHECK %0d FAIL: %s at %0t", checks,
                       description, $time);
        end
    endtask

    task automatic wait_for_stage;
        input [31:0] wanted;
        input integer maximum_cycles;
        integer stage_cycles;
        begin
            stage_cycles = 0;
            while (fw_stage !== wanted && fw_stage !== ST_FAILED &&
                   stage_cycles < maximum_cycles) begin
                @(posedge clk_board);
                stage_cycles = stage_cycles + 1;
            end
            if (fw_stage === ST_FAILED)
                $fatal(1, "Firmware failed at stage %0d", fw_failure);
            if (fw_stage !== wanted)
                $fatal(1, "Timeout waiting for stage %08h, current=%08h",
                       wanted, fw_stage);
        end
    endtask

    task automatic send_uart_rx;
        input [7:0] value;
        integer bit_number;
        begin
            @(negedge clk_board);
            uart_rx = 1'b0;
            repeat (CPB) @(negedge clk_board);
            for (bit_number = 0; bit_number < 8; bit_number = bit_number + 1) begin
                uart_rx = value[bit_number];
                repeat (CPB) @(negedge clk_board);
            end
            uart_rx = 1'b1;
            repeat (CPB) @(negedge clk_board);
        end
    endtask

    // 调度顺序、DMA AXI形状、LAST和CPU/DMA并行访问监视。
    always @(posedge clk_board) begin
        if (dut.reset_sys_n) begin
            irq_seen <= irq_seen | dut.irq[13:8];

            if (dut.u_fabric.dma_pending == 6'b111111)
                all_pending_seen = 1'b1;

            if ((dut.u_fabric.dma_busy &
                 (dut.u_fabric.dma_busy - 6'd1)) != 6'd0)
                $fatal(1, "More than one channel is BUSY");

            if (dut.u_fabric.u_dma.scheduler_claim) begin
                check(dut.u_fabric.u_dma.scheduler_channel ==
                      expected_claim[2:0],
                      "round-robin claim order is 0..5");
                expected_claim = expected_claim + 1;
                claim_count = claim_count + 1;
            end

            // 只统计ST_RUNNING之后的STATUS读取，排除配置/启动阶段的检查。
            // 每个DMA ISR都会读取自己通道的STATUS寄存器一次。
            if (dut.u_fabric.m_arvalid && dut.u_fabric.m_arready &&
                fw_stage == ST_RUNNING &&
                dut.u_fabric.m_araddr[31:12] == 20'h4000e &&
                dut.u_fabric.m_araddr[5:0] == 6'h10 &&
                dut.u_fabric.m_araddr[8:6] < 3'd6)
                cpu_irq_status_reads = cpu_irq_status_reads + 1;

            if (dut.u_fabric.d_arvalid && dut.u_fabric.d_arready) begin
                check(dut.u_fabric.d_arsize == 3'b010,
                      "all DMA reads are 32-bit");
                if (dut.u_fabric.d_araddr == FIR_INPUT_BASE ||
                    dut.u_fabric.d_araddr == UART_TX_BASE ||
                    dut.u_fabric.d_araddr == COPY4_SRC_BASE ||
                    dut.u_fabric.d_araddr == COPY5_SRC_BASE) begin
                    check(dut.u_fabric.d_arlen == 8'd15 &&
                          dut.u_fabric.d_arburst == 2'b01,
                          "SRAM source uses a 16-beat INCR read");
                end else if (dut.u_fabric.d_araddr == FIR_DATA_ADDR) begin
                    check(dut.u_fabric.d_arlen == 8'd15 &&
                          dut.u_fabric.d_arburst == 2'b00,
                          "FIR output uses a 16-beat FIXED read");
                end else if (dut.u_fabric.d_araddr == UART_RX_ADDR) begin
                    check(dut.u_fabric.d_arlen == 8'd0 &&
                          dut.u_fabric.d_arburst == 2'b01,
                          "UART RX uses paced single-beat reads");
                end else begin
                    $fatal(1, "Unexpected DMA AR address %08h",
                           dut.u_fabric.d_araddr);
                end
                active_arlen = dut.u_fabric.d_arlen;
                ar_beat = 0;
                dma_ar_count = dma_ar_count + 1;
            end

            if (dut.u_fabric.d_rvalid && dut.u_fabric.d_rready) begin
                check(dut.u_fabric.d_rlast == (ar_beat == active_arlen),
                      "DMA RLAST is on the final read beat");
                if (dut.u_fabric.d_rresp != 2'b00)
                    response_errors = response_errors + 1;
                if (dut.u_fabric.d_rlast)
                    ar_beat = 0;
                else
                    ar_beat = ar_beat + 1;
                dma_r_count = dma_r_count + 1;
            end

            if (dut.u_fabric.d_awvalid && dut.u_fabric.d_awready) begin
                check(dut.u_fabric.d_awsize == 3'b010,
                      "all DMA writes are 32-bit");
                if (dut.u_fabric.d_awaddr == FIR_DATA_ADDR) begin
                    check(dut.u_fabric.d_awlen == 8'd15 &&
                          dut.u_fabric.d_awburst == 2'b00,
                          "FIR input uses a 16-beat FIXED write");
                end else if (dut.u_fabric.d_awaddr == UART_TX_ADDR) begin
                    check(dut.u_fabric.d_awlen == 8'd0 &&
                          dut.u_fabric.d_awburst == 2'b01,
                          "UART TX uses paced single-beat writes");
                end else if (dut.u_fabric.d_awaddr == FIR_OUTPUT_BASE ||
                             dut.u_fabric.d_awaddr == UART_RX_BASE ||
                             dut.u_fabric.d_awaddr == COPY4_DST_BASE ||
                             dut.u_fabric.d_awaddr == COPY5_DST_BASE) begin
                    check(dut.u_fabric.d_awlen == 8'd15 &&
                          dut.u_fabric.d_awburst == 2'b01,
                          "SRAM destination uses a 16-beat INCR write");
                end else begin
                    $fatal(1, "Unexpected DMA AW address %08h",
                           dut.u_fabric.d_awaddr);
                end
                active_awlen = dut.u_fabric.d_awlen;
                aw_beat = 0;
                dma_aw_count = dma_aw_count + 1;
            end

            if (dut.u_fabric.d_wvalid && dut.u_fabric.d_wready) begin
                check(dut.u_fabric.d_wlast == (aw_beat == active_awlen),
                      "DMA WLAST is on the final write beat");
                if (dut.u_fabric.d_wlast)
                    aw_beat = 0;
                else
                    aw_beat = aw_beat + 1;
                dma_w_count = dma_w_count + 1;
            end

            if (dut.u_fabric.d_bvalid && dut.u_fabric.d_bready) begin
                if (dut.u_fabric.d_bresp != 2'b00)
                    response_errors = response_errors + 1;
                dma_b_count = dma_b_count + 1;
            end
        end
    end

    // 真实UART TX串行解码器。
    initial begin : uart_tx_monitor
        integer bit_number;
        reg [7:0] received;
        wait (dut.reset_sys_n === 1'b1);
        forever begin
            @(negedge uart_tx);
            repeat (CPB/2) @(posedge clk_board);
            if (uart_tx !== 1'b0)
                serial_errors = serial_errors + 1;
            for (bit_number = 0; bit_number < 8; bit_number = bit_number + 1) begin
                repeat (CPB) @(posedge clk_board);
                received[bit_number] = uart_tx;
            end
            repeat (CPB) @(posedge clk_board);
            if (uart_tx !== 1'b1)
                serial_errors = serial_errors + 1;
            if (tx_serial_count >= WORD_COUNT)
                $fatal(1, "UART transmitted extra DMA data");
            tx_serial_bytes[tx_serial_count] = received;
            tx_serial_count = tx_serial_count + 1;
        end
    end

    initial begin
        firmware_path = "../dma6_scenario_firmware.hex";
        if ($value$plusargs("firmware=%s", firmware_path)) begin end

        $display("============================================================");
        $display("Starting Cortex-M0 six-channel DMA integrated scenario");
        $display("Firmware: %0s", firmware_path);
        $display("============================================================");
        $readmemh(firmware_path,
                  dut.u_fabric.u_axi_interconnect.u_two_sram.u_code_sram
                     .u_simple_sram_core.memory);

        repeat (10) @(posedge clk_board);
        @(negedge clk_board);
        reset_n = 1'b1;

        $display("[TB] 1/4: wait until all six channels are PENDING");
        wait_for_stage(ST_ALL_PENDING, 50000);
        check(all_pending_seen, "PENDING=6'b111111 was observed");
        check(dut.u_fabric.dma_pending == 6'b111111,
              "all tasks remain pending while scheduler is paused");
        check(dut.u_fabric.dma_busy == 6'b000000,
              "no task is busy while scheduler is paused");
        check(fw_pending == 32'h0000_003f && fw_busy == 32'd0,
              "firmware read the global pending/busy masks");

        $display("[TB] 2/4: preload 16 UART RX characters while DMA is paused");
        for (index = 0; index < WORD_COUNT; index = index + 1)
            send_uart_rx(8'ha0 + index[7:0]);

        check(dut.u_fabric.dma_pending == 6'b111111,
              "serial input does not release the paused scheduler");
        @(negedge clk_board);
        dut.u_fabric.u_axi_interconnect.u_two_sram.u_data_sram
           .u_simple_sram_core.memory[MAILBOX_WORD + 3] = HOST_READY;

        $display("[TB] 3/4: scheduler executes channels 0..5 one at a time");
        wait_for_stage(ST_RUNNING, 50000);

        waited = 0;
        while ((fw_signature !== PASS_SIGNATURE ||
                tx_serial_count < WORD_COUNT) &&
               fw_signature !== FAIL_SIGNATURE &&
               waited < MAX_CYCLES) begin
            @(posedge clk_board);
            waited = waited + 1;
        end
        repeat (5) @(posedge clk_board);

        $display("[TB] 4/4: verify masks, IRQs, bus traffic and all data");
        $display("IRQ summary: stage=%08h signature=%08h failure=%0d pending=%06b busy=%06b done=%06b error=%06b irq_seen=%06b irq_now=%06b isr_reads=%0d lockup=%0b",
                 fw_stage, fw_signature, fw_failure,
                 dut.u_fabric.dma_pending, dut.u_fabric.dma_busy,
                 dut.u_fabric.dma_done, dut.u_fabric.dma_error,
                 irq_seen, dut.irq[13:8], cpu_irq_status_reads,
                 dut.cpu_lockup);
        check(fw_signature == PASS_SIGNATURE,
              "six-channel C firmware reports PASS");
        check(fw_stage == ST_ALL_DONE, "firmware reached ST_ALL_DONE");
        check(fw_failure == 32'd0, "firmware failure stage remains zero");
        check(fw_pending == 32'd0 && fw_busy == 32'd0 &&
              fw_done == 32'd0 && fw_error == 32'd0,
              "ISR W1C left no pending, busy, done or error status");
        check(fw_irq_done_events == 32'h0000_003f &&
              fw_irq_error_events == 32'd0,
              "six ISR completion events were recorded without error");
        check(fw_fir_status == 32'h0000_0002,
              "FIR completed without overflow");
        check(claim_count == 6 && expected_claim == 6,
              "exactly six channels were scheduled in order");
        check(dut.u_fabric.dma_done == 6'b000000 &&
              dut.u_fabric.dma_error == 6'b000000,
              "all sticky DMA status bits were cleared by their ISR");
        check(irq_seen == 6'b111111 && dut.irq[13:8] == 6'b000000,
              "IRQ[8:13] all asserted and were deasserted by W1C");
        check(cpu_irq_status_reads == 6,
              "each DMA ISR read exactly one channel STATUS register");
        check(response_errors == 0, "all DMA AXI responses are OKAY");
        check(dma_ar_count == 21 && dma_aw_count == 21,
              "expected burst/single-beat AR and AW transaction counts");
        check(dma_r_count == 96 && dma_w_count == 96 && dma_b_count == 21,
              "all 96 read/write beats and 21 B responses completed");
        check(tx_serial_count == WORD_COUNT && serial_errors == 0,
              "UART transmitted exactly 16 valid serial frames");
        check(!dut.fabric_error && !dut.cpu_lockup &&
              !dut.cpu_sysresetreq && !led_error,
              "SoC completed without fabric or CPU fault");

        for (index = 0; index < 6; index = index + 1)
            check(dut.u_fabric.u_axi_interconnect.u_two_sram.u_data_sram
                     .u_simple_sram_core.memory[MAILBOX_WORD + 11 + index] == 32'd1,
                  "each channel ISR ran exactly once");

        for (index = 0; index < WORD_COUNT; index = index + 1) begin
            check(dut.u_fabric.u_axi_interconnect.u_two_sram.u_data_sram
                     .u_simple_sram_core.memory[(32'h1400 >> 2) + index] ===
                  expected_fir_output(index),
                  "FIR output matches the Q15 reference");
            check(dut.u_fabric.u_axi_interconnect.u_two_sram.u_data_sram
                     .u_simple_sram_core.memory[(32'h1700 >> 2) + index] ===
                  (32'h0000_00a0 + index),
                  "UART RX DMA output matches serial input");
            check(dut.u_fabric.u_axi_interconnect.u_two_sram.u_data_sram
                     .u_simple_sram_core.memory[(32'h1900 >> 2) + index] ===
                  (32'h4400_0000 + index),
                  "channel 4 SRAM copy is correct");
            check(dut.u_fabric.u_axi_interconnect.u_two_sram.u_data_sram
                     .u_simple_sram_core.memory[(32'h1b00 >> 2) + index] ===
                  (32'h5500_0000 + index),
                  "channel 5 SRAM copy is correct");
            check(tx_serial_bytes[index] == (8'h40 + index[7:0]),
                  "UART TX serial byte matches SRAM input");
        end

        check(dut.u_fabric.u_axi_interconnect.u_two_sram.u_data_sram
                 .u_simple_sram_core.memory[(32'h1440 >> 2)] == GUARD_VALUE &&
              dut.u_fabric.u_axi_interconnect.u_two_sram.u_data_sram
                 .u_simple_sram_core.memory[(32'h1740 >> 2)] == GUARD_VALUE &&
              dut.u_fabric.u_axi_interconnect.u_two_sram.u_data_sram
                 .u_simple_sram_core.memory[(32'h1940 >> 2)] == GUARD_VALUE &&
              dut.u_fabric.u_axi_interconnect.u_two_sram.u_data_sram
                 .u_simple_sram_core.memory[(32'h1b40 >> 2)] == GUARD_VALUE,
              "all destination guard words remain unchanged");

        $display("------------------------------------------------------------");
        $display("Claims=%0d AR=%0d R=%0d AW=%0d W=%0d B=%0d ISR-reads=%0d",
                 claim_count, dma_ar_count, dma_r_count, dma_aw_count,
                 dma_w_count, dma_b_count, cpu_irq_status_reads);
        $display("TEST PASS: Cortex-M0 completed the six-channel DMA scenario");
        $display("All six DMA interrupts ran exactly once and all data is correct");
        $display("Checks: %0d", checks);
        $display("============================================================");
        $finish;
    end

    initial begin
        #20000000;
        $fatal(1, "TEST FAIL: six-channel DMA integrated scenario timeout");
    end

endmodule
