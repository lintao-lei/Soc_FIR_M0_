`timescale 1ns/1ps

module tb_soc_top_cpu_uart_echo;
    localparam integer CPB = 434;
    localparam integer MAX_BYTES = 128;

    localparam [31:0] PASS_SIGNATURE = 32'h5041_5353;
    localparam [31:0] FAIL_SIGNATURE = 32'h4641_494c;

    localparam [31:0] ST_WAIT_SINGLE     = 32'h0000_0020;
    localparam [31:0] ST_WAIT_STRING     = 32'h0000_0030;
    localparam [31:0] ST_WAIT_CONTINUOUS = 32'h0000_0040;
    localparam [31:0] ST_WAIT_RX_FULL    = 32'h0000_0050;
    localparam [31:0] ST_RX_FULL_SEEN    = 32'h0000_0051;
    localparam [31:0] ST_RX_DRAIN_DONE   = 32'h0000_0052;
    localparam [31:0] ST_TX_FULL_SEEN    = 32'h0000_0061;
    localparam [31:0] ST_TX_TIMEOUT_DONE = 32'h0000_0062;
    localparam [31:0] ST_TX_EMPTY_SEEN   = 32'h0000_0063;
    localparam [31:0] ST_ALL_DONE        = 32'h0000_0070;
    localparam [31:0] ST_FAILED          = 32'h0000_00ff;

    reg clk_board = 1'b0;
    always #10 clk_board = ~clk_board;

    reg reset_n = 1'b0;
    reg uart_rx = 1'b1;
    wire uart_tx;
    wire led_run;
    wire led_error;

    integer checks = 0;
    integer uart_reads = 0;
    integer uart_writes = 0;
    integer bus_errors = 0;
    integer serial_errors = 0;
    integer expected_count = 0;
    integer actual_count = 0;
    integer index;
    integer fill_count;
    integer stable_count;

    reg [7:0] expected_bytes [0:MAX_BYTES-1];
    reg [7:0] actual_bytes [0:MAX_BYTES-1];
    reg seen_rx_full_stage = 1'b0;
    reg seen_rx_drain_stage = 1'b0;
    reg seen_tx_full_stage = 1'b0;
    reg seen_tx_timeout_stage = 1'b0;
    reg seen_tx_empty_stage = 1'b0;
    reg seen_hw_rx_full = 1'b0;
    reg seen_hw_tx_full = 1'b0;

    soc_top dut (
        .clk_board(clk_board),
        .reset_n(reset_n),
        .uart_rx(uart_rx),
        .uart_tx(uart_tx),
        .led_run(led_run),
        .led_error(led_error)
    );

    /* 数据 SRAM 前 7 个 word 是固件与 testbench 之间的结果邮箱。 */
    wire [31:0] fw_stage =
        dut.u_fabric.u_axi_interconnect.u_two_sram.u_data_sram
           .u_simple_sram_core.memory[0];
    wire [31:0] fw_signature =
        dut.u_fabric.u_axi_interconnect.u_two_sram.u_data_sram
           .u_simple_sram_core.memory[1];
    wire [31:0] fw_error =
        dut.u_fabric.u_axi_interconnect.u_two_sram.u_data_sram
           .u_simple_sram_core.memory[2];
    wire [31:0] fw_rx_count =
        dut.u_fabric.u_axi_interconnect.u_two_sram.u_data_sram
           .u_simple_sram_core.memory[3];
    wire [31:0] fw_tx_count =
        dut.u_fabric.u_axi_interconnect.u_two_sram.u_data_sram
           .u_simple_sram_core.memory[4];
    wire [31:0] fw_tx_fill_count =
        dut.u_fabric.u_axi_interconnect.u_two_sram.u_data_sram
           .u_simple_sram_core.memory[5];
    wire [31:0] fw_last_status =
        dut.u_fabric.u_axi_interconnect.u_two_sram.u_data_sram
           .u_simple_sram_core.memory[6];

    task automatic check(input bit good, input string what);
        begin
            checks = checks + 1;
            if (!good)
                $fatal(1, "CHECK %0d FAIL: %s at %0t", checks, what, $time);
        end
    endtask

    task automatic append_expected(input [7:0] value);
        begin
            if (expected_count >= MAX_BYTES)
                $fatal(1, "Expected-byte scoreboard overflow");
            expected_bytes[expected_count] = value;
            expected_count = expected_count + 1;
        end
    endtask

    task automatic wait_for_stage(input [31:0] wanted,
                                  input integer max_cycles);
        integer waited;
        begin
            waited = 0;
            while (fw_stage !== wanted &&
                   fw_stage !== ST_FAILED &&
                   waited < max_cycles) begin
                @(posedge clk_board);
                waited = waited + 1;
            end
            if (fw_stage === ST_FAILED)
                $fatal(1, "Firmware failed: error=0x%08h", fw_error);
            if (fw_stage !== wanted)
                $fatal(1,
                    "Timeout waiting for firmware stage 0x%08h; current=0x%08h",
                    wanted, fw_stage);
        end
    endtask

    /* 8-N-1 UART 输入。extra_idle_bits=0 表示真正连续的相邻字符。 */
    task automatic send_uart_rx(input [7:0] value,
                                input integer extra_idle_bits);
        integer bit_no;
        begin
            @(negedge clk_board);
            uart_rx = 1'b0;
            repeat (CPB) @(negedge clk_board);
            for (bit_no = 0; bit_no < 8; bit_no = bit_no + 1) begin
                uart_rx = value[bit_no];
                repeat (CPB) @(negedge clk_board);
            end
            uart_rx = 1'b1;
            repeat (CPB) @(negedge clk_board);
            repeat (extra_idle_bits * CPB) @(negedge clk_board);
        end
    endtask

    task automatic send_and_expect(input [7:0] value,
                                   input integer extra_idle_bits);
        begin
            append_expected(value);
            send_uart_rx(value, extra_idle_bits);
        end
    endtask

    function automatic [7:0] string_byte(input integer item);
        begin
            case (item)
                0:  string_byte = "H";
                1:  string_byte = "e";
                2:  string_byte = "l";
                3:  string_byte = "l";
                4:  string_byte = "o";
                5:  string_byte = " ";
                6:  string_byte = "U";
                7:  string_byte = "A";
                8:  string_byte = "R";
                9:  string_byte = "T";
                10: string_byte = "!";
                11: string_byte = 8'h0d;
                default: string_byte = 8'h0a;
            endcase
        end
    endfunction

    function automatic [7:0] continuous_byte(input integer item);
        begin
            case (item)
                0: continuous_byte = 8'h00;
                1: continuous_byte = 8'h55;
                2: continuous_byte = 8'haa;
                3: continuous_byte = 8'hff;
                4: continuous_byte = 8'h81;
                5: continuous_byte = 8'h18;
                6: continuous_byte = 8'h7e;
                default: continuous_byte = 8'h42;
            endcase
        end
    endfunction

    /* 统计真实 CPU 总线对 UART 窗口的访问和所有错误响应。 */
    always @(posedge clk_board) begin
        if (dut.reset_sys_n) begin
            if (dut.u_fabric.m_awvalid && dut.u_fabric.m_awready &&
                dut.u_fabric.m_awaddr[31:12] == 20'h40004)
                uart_writes = uart_writes + 1;
            if (dut.u_fabric.m_arvalid && dut.u_fabric.m_arready &&
                dut.u_fabric.m_araddr[31:12] == 20'h40004)
                uart_reads = uart_reads + 1;
            if (dut.u_fabric.m_bvalid && dut.u_fabric.m_bready &&
                dut.u_fabric.m_bresp != 2'b00)
                bus_errors = bus_errors + 1;
            if (dut.u_fabric.m_rvalid && dut.u_fabric.m_rready &&
                dut.u_fabric.m_rresp != 2'b00)
                bus_errors = bus_errors + 1;

            case (fw_stage)
                ST_RX_FULL_SEEN:    seen_rx_full_stage = 1'b1;
                ST_RX_DRAIN_DONE:   seen_rx_drain_stage = 1'b1;
                ST_TX_FULL_SEEN:    seen_tx_full_stage = 1'b1;
                ST_TX_TIMEOUT_DONE: seen_tx_timeout_stage = 1'b1;
                ST_TX_EMPTY_SEEN:   seen_tx_empty_stage = 1'b1;
                default: ;
            endcase

            if (dut.u_fabric.u_axi_interconnect.u_uart_subsystem.u_uart
                   .u_apb_uart.rx_count == 5'd16)
                seen_hw_rx_full = 1'b1;
            if (dut.u_fabric.u_axi_interconnect.u_uart_subsystem.u_uart
                   .u_apb_uart.tx_count == 5'd16)
                seen_hw_tx_full = 1'b1;
        end
    end

    /*
     * 独立串口输出监视器。它从复位释放后一直工作，所以 CPU 在输入任务
     * 尚未结束时产生的早期回显也不会丢失。
     */
    initial begin : uart_tx_monitor
        integer bit_no;
        reg [7:0] received;

        wait (dut.reset_sys_n === 1'b1);
        forever begin
            @(negedge uart_tx);
            repeat (CPB/2) @(posedge clk_board);
            if (uart_tx !== 1'b0)
                serial_errors = serial_errors + 1;
            for (bit_no = 0; bit_no < 8; bit_no = bit_no + 1) begin
                repeat (CPB) @(posedge clk_board);
                received[bit_no] = uart_tx;
            end
            repeat (CPB) @(posedge clk_board);
            if (uart_tx !== 1'b1)
                serial_errors = serial_errors + 1;
            if (actual_count >= MAX_BYTES)
                $fatal(1, "Actual-byte scoreboard overflow");
            actual_bytes[actual_count] = received;
            actual_count = actual_count + 1;
        end
    end

    /* 40 ms 的独立硬超时，防止任何软件或总线死锁。 */
    initial begin
        #40000000;
        $display("UART echo timeout debug:");
        $display("  stage=0x%08h signature=0x%08h error=0x%08h",
                 fw_stage, fw_signature, fw_error);
        $display("  rx=%0d tx=%0d fill=%0d actual=%0d expected=%0d",
                 fw_rx_count, fw_tx_count, fw_tx_fill_count,
                 actual_count, expected_count);
        $display("  uart_reads=%0d uart_writes=%0d bus_errors=%0d",
                 uart_reads, uart_writes, bus_errors);
        $fatal(1, "TEST FAIL: Cortex-M0 UART echo timeout");
    end

    initial begin : test_sequence
        /* XSim 的工作目录是本测试旁边的 xsim_work_* 子目录。 */
        $readmemh(
            "../uart_echo_firmware.hex",
            dut.u_fabric.u_axi_interconnect.u_two_sram.u_code_sram
               .u_simple_sram_core.memory);

        for (index = 0; index < 7; index = index + 1)
            dut.u_fabric.u_axi_interconnect.u_two_sram.u_data_sram
               .u_simple_sram_core.memory[index] = 32'd0;

        repeat (10) @(posedge clk_board);
        @(negedge clk_board);
        reset_n = 1'b1;

        $display("[TB] 1/6: single-character polling echo");
        wait_for_stage(ST_WAIT_SINGLE, 100000);
        send_and_expect(8'h41, 2);

        $display("[TB] 2/6: string echo");
        wait_for_stage(ST_WAIT_STRING, 100000);
        for (index = 0; index < 13; index = index + 1)
            send_and_expect(string_byte(index), 0);

        $display("[TB] 3/6: continuous characters with no extra idle bit");
        wait_for_stage(ST_WAIT_CONTINUOUS, 100000);
        for (index = 0; index < 8; index = index + 1)
            send_and_expect(continuous_byte(index), 0);

        $display("[TB] 4/6: fill all 16 RX FIFO entries, then drain/echo");
        wait_for_stage(ST_WAIT_RX_FULL, 100000);
        for (index = 0; index < 16; index = index + 1)
            send_and_expect(8'h60 + index[7:0], 0);

        $display("[TB] 5/6: TX FIFO full, software timeout, then drain");
        wait_for_stage(ST_ALL_DONE, 1500000);
        check(fw_signature === PASS_SIGNATURE,
              "firmware wrote PASS signature");
        check(fw_error === 32'd0, "firmware error code is zero");

        fill_count = fw_tx_fill_count;
        check(fill_count >= 16 && fill_count <= 17,
              "TX fill accepted 16 or 17 bytes");
        for (index = 0; index < fill_count; index = index + 1)
            append_expected(8'hc0 + index[7:0]);

        /* 固件写 PASS 时最后一个字节可能仍在串行移位，继续等待监视器。 */
        stable_count = 0;
        while (actual_count < expected_count && stable_count < 200000) begin
            @(posedge clk_board);
            stable_count = stable_count + 1;
        end
        check(actual_count == expected_count,
              "all expected UART frames were transmitted");

        /* 再等待完整一帧，证明超时测试中的 0xEE 没有被错误排入 FIFO。 */
        stable_count = actual_count;
        repeat (11 * CPB) @(posedge clk_board);
        check(actual_count == stable_count,
              "no duplicate or unexpected extra UART frame");

        $display("[TB] 6/6: final scoreboards and FIFO/status checks");
        check(serial_errors == 0, "all UART start/stop bits were valid");
        check(actual_count == expected_count,
              "UART output byte count matches exactly");
        for (index = 0; index < expected_count; index = index + 1)
            check(actual_bytes[index] === expected_bytes[index],
                  "UART echoed byte and ordering match");

        check(fw_rx_count == 32'd38,
              "CPU received 1+13+8+16 bytes");
        check(fw_tx_count == (32'd38 + fw_tx_fill_count),
              "CPU transmit-success counter is exact");
        check(seen_rx_full_stage && seen_hw_rx_full,
              "RX FIFO full was observed by software and hardware");
        check(seen_rx_drain_stage,
              "RX FIFO was drained after the full test");
        check(seen_tx_full_stage && seen_hw_tx_full,
              "TX FIFO full was observed by software and hardware");
        check(seen_tx_timeout_stage,
              "TX full software timeout completed");
        check(seen_tx_empty_stage,
              "TX FIFO empty was observed after draining");
        check((fw_last_status & 32'h0000_0002) == 0,
              "RX FIFO is empty in final status");
        check((fw_last_status & 32'h0000_0008) != 0,
              "TX FIFO is empty in final status");
        check((fw_last_status & 32'h0000_0004) == 0,
              "no sticky UART frame error");
        check(bus_errors == 0, "no CPU AXI error response");
        check(uart_reads > 0 && uart_writes > 0,
              "CPU really accessed UART through the bus");
        check(!dut.fabric_error && !led_error,
              "SoC fabric and LED report no error");
        check(uart_tx === 1'b1, "UART TX line returned to idle-high");

        $display("============================================================");
        $display("TEST PASS: Cortex-M0 polling UART full echo regression");
        $display("Echo bytes=%0d, TX-fill bytes=%0d, total TX bytes=%0d",
                 fw_rx_count, fw_tx_fill_count, actual_count);
        $display("UART MMIO reads=%0d writes=%0d, checks=%0d",
                 uart_reads, uart_writes, checks);
        $display("Covered: single, string, continuous, RX full/empty,");
        $display("         TX full/empty, RX/TX timeout and zero-data-error.");
        $display("============================================================");
        $finish;
    end
endmodule
