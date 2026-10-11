`timescale 1ns/1ps

// Self-checking verification for the FIR subsystem, including bus recovery,
// FIFO flush and backpressure corner cases.
module tb_fir_subsystem;

    localparam integer N_TAP       = 81;
    localparam integer FIFO_DEPTH  = 32;
    localparam integer MAX_SAMPLES = 160;
    localparam [31:0]  DATA_BASE   = 32'h4000_1000;

    localparam [11:0] ADDR_CTRL   = 12'h000;
    localparam [11:0] ADDR_STATUS = 12'h004;
    localparam [11:0] ADDR_DATA_IN = 12'h008;
    localparam [11:0] ADDR_COEFF0 = 12'h010;
    localparam [11:0] ADDR_LEN    = 12'h158;
    localparam [11:0] ADDR_IRQ_EN = 12'h15C;

    reg aclk;
    reg aresetn;

    reg  [11:0] ctrl_awaddr;
    reg         ctrl_awvalid;
    wire        ctrl_awready;
    reg  [31:0] ctrl_wdata;
    reg  [ 3:0] ctrl_wstrb;
    reg         ctrl_wvalid;
    wire        ctrl_wready;
    wire [ 1:0] ctrl_bresp;
    wire        ctrl_bvalid;
    reg         ctrl_bready;
    reg  [11:0] ctrl_araddr;
    reg         ctrl_arvalid;
    wire        ctrl_arready;
    wire [31:0] ctrl_rdata;
    wire [ 1:0] ctrl_rresp;
    wire        ctrl_rvalid;
    reg         ctrl_rready;

    reg  [31:0] data_awaddr;
    reg  [ 7:0] data_awlen;
    reg  [ 2:0] data_awsize;
    reg  [ 1:0] data_awburst;
    reg         data_awvalid;
    wire        data_awready;
    reg  [31:0] data_wdata;
    reg  [ 3:0] data_wstrb;
    reg         data_wlast;
    reg         data_wvalid;
    wire        data_wready;
    wire [ 1:0] data_bresp;
    wire        data_bvalid;
    reg         data_bready;
    reg  [31:0] data_araddr;
    reg  [ 7:0] data_arlen;
    reg  [ 2:0] data_arsize;
    reg  [ 1:0] data_arburst;
    reg         data_arvalid;
    wire        data_arready;
    wire [31:0] data_rdata;
    wire [ 1:0] data_rresp;
    wire        data_rlast;
    wire        data_rvalid;
    reg         data_rready;

    wire irq_done;
    wire irq_ovf;

    integer coeff_model   [0:N_TAP-1];
    integer history_model [0:N_TAP-1];
    integer sample_model  [0:MAX_SAMPLES-1];
    reg signed [31:0] expected_model [0:MAX_SAMPLES-1];

    integer check_count;
    integer error_count;
    integer requirement_failure_count;
    integer known_issue_count;
    integer max_input_run;
    integer current_input_run;
    integer core_stall_cycles;
    integer axi_r_stall_cycles;
    integer random_seed;

    reg        core_stall_previous;
    reg [31:0] core_stall_data;
    reg        axi_r_stall_previous;
    reg [31:0] axi_r_stall_data;
    reg [ 1:0] axi_r_stall_resp;
    reg        axi_r_stall_last;

    fir_subsystem #(
        .N_TAP(N_TAP),
        .FIFO_DEPTH(FIFO_DEPTH)
    ) dut (
        .aclk          (aclk),
        .aresetn       (aresetn),

        .ctrl_awaddr   (ctrl_awaddr),
        .ctrl_awvalid  (ctrl_awvalid),
        .ctrl_awready  (ctrl_awready),
        .ctrl_wdata    (ctrl_wdata),
        .ctrl_wstrb    (ctrl_wstrb),
        .ctrl_wvalid   (ctrl_wvalid),
        .ctrl_wready   (ctrl_wready),
        .ctrl_bresp    (ctrl_bresp),
        .ctrl_bvalid   (ctrl_bvalid),
        .ctrl_bready   (ctrl_bready),
        .ctrl_araddr   (ctrl_araddr),
        .ctrl_arvalid  (ctrl_arvalid),
        .ctrl_arready  (ctrl_arready),
        .ctrl_rdata    (ctrl_rdata),
        .ctrl_rresp    (ctrl_rresp),
        .ctrl_rvalid   (ctrl_rvalid),
        .ctrl_rready   (ctrl_rready),

        .data_awaddr   (data_awaddr),
        .data_awlen    (data_awlen),
        .data_awsize   (data_awsize),
        .data_awburst  (data_awburst),
        .data_awvalid  (data_awvalid),
        .data_awready  (data_awready),
        .data_wdata    (data_wdata),
        .data_wstrb    (data_wstrb),
        .data_wlast    (data_wlast),
        .data_wvalid   (data_wvalid),
        .data_wready   (data_wready),
        .data_bresp    (data_bresp),
        .data_bvalid   (data_bvalid),
        .data_bready   (data_bready),
        .data_araddr   (data_araddr),
        .data_arlen    (data_arlen),
        .data_arsize   (data_arsize),
        .data_arburst  (data_arburst),
        .data_arvalid  (data_arvalid),
        .data_arready  (data_arready),
        .data_rdata    (data_rdata),
        .data_rresp    (data_rresp),
        .data_rlast    (data_rlast),
        .data_rvalid   (data_rvalid),
        .data_rready   (data_rready),

        .irq_done      (irq_done),
        .irq_ovf       (irq_ovf)
    );

    always #5 aclk = ~aclk;

    function automatic signed [31:0] quantize_q15;
        input signed [63:0] value;
        reg signed [63:0] magnitude;
        reg signed [63:0] rounded;
        begin
            if (value < 0) begin
                magnitude = -value;
                rounded = -((magnitude + 64'sd16384) >>> 15);
            end else begin
                rounded = (value + 64'sd16384) >>> 15;
            end

            if (rounded > 64'sd2147483647)
                quantize_q15 = 32'sh7fff_ffff;
            else if (rounded < -64'sd2147483648)
                quantize_q15 = 32'sh8000_0000;
            else
                quantize_q15 = rounded[31:0];
        end
    endfunction

    task automatic record_check;
        input condition;
        input [8*120-1:0] description;
        begin
            check_count = check_count + 1;
            if (condition) begin
                $display("[%0t] CHECK %0d PASS: %0s", $time, check_count,
                         description);
            end else begin
                error_count = error_count + 1;
                $display("[%0t] CHECK %0d FAIL: %0s", $time, check_count,
                         description);
            end
        end
    endtask

    task automatic record_requirement_failure;
        input [8*160-1:0] description;
        begin
            requirement_failure_count = requirement_failure_count + 1;
            known_issue_count = known_issue_count + 1;
            $display("[%0t] REQUIREMENT FAIL: %0s", $time, description);
        end
    endtask

    task automatic drive_idle;
        begin
            ctrl_awaddr   = 12'd0;
            ctrl_awvalid  = 1'b0;
            ctrl_wdata    = 32'd0;
            ctrl_wstrb    = 4'd0;
            ctrl_wvalid   = 1'b0;
            ctrl_bready   = 1'b0;
            ctrl_araddr   = 12'd0;
            ctrl_arvalid  = 1'b0;
            ctrl_rready   = 1'b0;

            data_awaddr   = DATA_BASE;
            data_awlen    = 8'd0;
            data_awsize   = 3'd2;
            data_awburst  = 2'b01;
            data_awvalid  = 1'b0;
            data_wdata    = 32'd0;
            data_wstrb    = 4'b1111;
            data_wlast    = 1'b0;
            data_wvalid   = 1'b0;
            data_bready   = 1'b0;
            data_araddr   = DATA_BASE;
            data_arlen    = 8'd0;
            data_arsize   = 3'd2;
            data_arburst  = 2'b01;
            data_arvalid  = 1'b0;
            data_rready   = 1'b0;
        end
    endtask

    task automatic apply_reset;
        begin
            drive_idle();
            aresetn = 1'b0;
            repeat (5) @(posedge aclk);
            @(negedge aclk);
            aresetn = 1'b1;
            repeat (3) @(posedge aclk);
        end
    endtask

    task automatic axil_write;
        input [11:0] address;
        input [31:0] value;
        input [ 3:0] strobe;
        input [ 1:0] expected_response;
        integer timeout;
        reg aw_done;
        reg w_done;
        begin
            @(negedge aclk);
            ctrl_awaddr  = address;
            ctrl_awvalid = 1'b1;
            ctrl_wdata   = value;
            ctrl_wstrb   = strobe;
            ctrl_wvalid  = 1'b1;
            aw_done = 1'b0;
            w_done  = 1'b0;
            timeout = 0;

            while ((!aw_done || !w_done) && timeout < 100) begin
                @(posedge aclk);
                if (ctrl_awvalid && ctrl_awready)
                    aw_done = 1'b1;
                if (ctrl_wvalid && ctrl_wready)
                    w_done = 1'b1;
                @(negedge aclk);
                if (aw_done)
                    ctrl_awvalid = 1'b0;
                if (w_done)
                    ctrl_wvalid = 1'b0;
                timeout = timeout + 1;
            end
            if (!aw_done || !w_done) begin
                record_check(1'b0, "AXI-Lite write address/data handshake timeout");
            end

            ctrl_bready = 1'b1;
            timeout = 0;
            while (!ctrl_bvalid && timeout < 100) begin
                @(posedge aclk);
                timeout = timeout + 1;
            end
            if (!ctrl_bvalid) begin
                record_check(1'b0, "AXI-Lite write response timeout");
            end else begin
                record_check(ctrl_bresp == expected_response,
                             "AXI-Lite write response matches expectation");
                @(posedge aclk);
            end
            @(negedge aclk);
            ctrl_bready = 1'b0;
        end
    endtask

    task automatic axil_read;
        input  [11:0] address;
        output [31:0] value;
        input  [ 1:0] expected_response;
        integer timeout;
        reg ar_done;
        begin
            value = 32'd0;
            @(negedge aclk);
            ctrl_araddr  = address;
            ctrl_arvalid = 1'b1;
            ar_done = 1'b0;
            timeout = 0;
            while (!ar_done && timeout < 100) begin
                @(posedge aclk);
                if (ctrl_arvalid && ctrl_arready)
                    ar_done = 1'b1;
                @(negedge aclk);
                if (ar_done)
                    ctrl_arvalid = 1'b0;
                timeout = timeout + 1;
            end
            if (!ar_done)
                record_check(1'b0, "AXI-Lite read address handshake timeout");

            ctrl_rready = 1'b1;
            timeout = 0;
            while (!ctrl_rvalid && timeout < 100) begin
                @(posedge aclk);
                timeout = timeout + 1;
            end
            if (!ctrl_rvalid) begin
                record_check(1'b0, "AXI-Lite read response timeout");
            end else begin
                value = ctrl_rdata;
                record_check(ctrl_rresp == expected_response,
                             "AXI-Lite read response matches expectation");
                @(posedge aclk);
            end
            @(negedge aclk);
            ctrl_rready = 1'b0;
        end
    endtask

    task automatic clear_models;
        integer index;
        begin
            for (index = 0; index < N_TAP; index = index + 1) begin
                coeff_model[index] = 0;
                history_model[index] = 0;
            end
            for (index = 0; index < MAX_SAMPLES; index = index + 1) begin
                sample_model[index] = 0;
                expected_model[index] = 32'sd0;
            end
        end
    endtask

    task automatic build_expected;
        input integer sample_count;
        integer sample_index;
        integer tap_index;
        reg signed [63:0] accumulator;
        reg signed [63:0] product;
        begin
            for (tap_index = 0; tap_index < N_TAP; tap_index = tap_index + 1)
                history_model[tap_index] = 0;

            for (sample_index = 0; sample_index < sample_count;
                 sample_index = sample_index + 1) begin
                for (tap_index = N_TAP-1; tap_index > 0;
                     tap_index = tap_index - 1)
                    history_model[tap_index] = history_model[tap_index-1];
                history_model[0] = sample_model[sample_index];

                accumulator = 64'sd0;
                for (tap_index = 0; tap_index < N_TAP;
                     tap_index = tap_index + 1) begin
                    product = coeff_model[tap_index] *
                              history_model[tap_index];
                    accumulator = accumulator + product;
                end
                expected_model[sample_index] = quantize_q15(accumulator);
            end
        end
    endtask

    task automatic configure_fir;
        input integer sample_count;
        integer tap_index;
        begin
            // Disable and clear arithmetic history/status.
            axil_write(ADDR_CTRL, 32'h0000_0004, 4'b0001, 2'b00);

            for (tap_index = 0; tap_index < N_TAP;
                 tap_index = tap_index + 1) begin
                axil_write(ADDR_COEFF0 + tap_index*4,
                           coeff_model[tap_index] & 32'h0000_ffff,
                           4'b0011, 2'b00);
            end

            // Atomically copy all shadow coefficients into the working bank.
            axil_write(ADDR_CTRL, 32'h0000_0002, 4'b0001, 2'b00);
            axil_write(ADDR_LEN, sample_count, 4'b0011, 2'b00);
            axil_write(ADDR_IRQ_EN, 32'h0000_0003, 4'b0001, 2'b00);
            axil_write(ADDR_CTRL, 32'h0000_0001, 4'b0001, 2'b00);
        end
    endtask

    task automatic send_data_burst;
        input integer sample_count;
        input [1:0] expected_response;
        integer beat;
        integer timeout;
        reg aw_done;
        reg beat_done;
        begin
            @(negedge aclk);
            data_awaddr  = DATA_BASE;
            data_awlen   = sample_count - 1;
            data_awsize  = 3'd2;
            data_awburst = 2'b01;
            data_awvalid = 1'b1;
            aw_done = 1'b0;
            timeout = 0;
            while (!aw_done && timeout < 200) begin
                @(posedge aclk);
                if (data_awvalid && data_awready)
                    aw_done = 1'b1;
                @(negedge aclk);
                if (aw_done)
                    data_awvalid = 1'b0;
                timeout = timeout + 1;
            end
            if (!aw_done)
                record_check(1'b0, "AXI data write-address handshake timeout");

            for (beat = 0; beat < sample_count; beat = beat + 1) begin
                data_wdata  = sample_model[beat] & 32'h0000_ffff;
                data_wstrb  = 4'b1111;
                data_wlast  = (beat == sample_count-1);
                data_wvalid = 1'b1;
                timeout = 0;
                beat_done = 1'b0;
                // A transfer is counted only when VALID and READY are both
                // sampled high on a rising edge.  Observing READY high after
                // an edge is not, by itself, a completed handshake.
                while (!beat_done && timeout < 2000) begin
                    @(posedge aclk);
                    if (data_wvalid && data_wready)
                        beat_done = 1'b1;
                    timeout = timeout + 1;
                end
                if (!beat_done) begin
                    record_check(1'b0, "AXI data write beat timeout");
                    beat = sample_count;
                end else begin
                    @(negedge aclk);
                end
            end
            data_wvalid = 1'b0;
            data_wlast  = 1'b0;

            data_bready = 1'b1;
            timeout = 0;
            while (!data_bvalid && timeout < 500) begin
                @(posedge aclk);
                timeout = timeout + 1;
            end
            if (!data_bvalid) begin
                record_check(1'b0, "AXI data write response timeout");
            end else begin
                record_check(data_bresp == expected_response,
                             "AXI data write response matches expectation");
                @(posedge aclk);
            end
            @(negedge aclk);
            data_bready = 1'b0;
        end
    endtask

    task automatic receive_and_check_burst;
        input integer sample_count;
        input integer insert_backpressure;
        integer beat;
        integer timeout;
        integer ready_pattern;
        reg ar_done;
        begin
            @(negedge aclk);
            data_araddr  = DATA_BASE;
            data_arlen   = sample_count - 1;
            data_arsize  = 3'd2;
            data_arburst = 2'b01;
            data_arvalid = 1'b1;
            ar_done = 1'b0;
            timeout = 0;
            while (!ar_done && timeout < 200) begin
                @(posedge aclk);
                if (data_arvalid && data_arready)
                    ar_done = 1'b1;
                @(negedge aclk);
                if (ar_done)
                    data_arvalid = 1'b0;
                timeout = timeout + 1;
            end
            if (!ar_done)
                record_check(1'b0, "AXI data read-address handshake timeout");

            beat = 0;
            timeout = 0;
            ready_pattern = 0;
            while (beat < sample_count && timeout < 5000) begin
                @(negedge aclk);
                if (insert_backpressure != 0)
                    data_rready = ((ready_pattern % 4) != 1);
                else
                    data_rready = 1'b1;
                ready_pattern = ready_pattern + 1;
                @(posedge aclk);
                if (data_rvalid && data_rready) begin
                    record_check(data_rresp == 2'b00,
                                 "AXI data read response is OKAY");
                    if ($signed(data_rdata) !==
                        $signed(expected_model[beat])) begin
                        $display("[%0t] OUTPUT MISMATCH beat=%0d expected=%0d (0x%08h) actual=%0d (0x%08h)",
                                 $time, beat, $signed(expected_model[beat]),
                                 expected_model[beat], $signed(data_rdata),
                                 data_rdata);
                    end
                    record_check($signed(data_rdata) ===
                                 $signed(expected_model[beat]),
                                 "FIR output matches independent Q15 reference");
                    record_check(data_rlast == (beat == sample_count-1),
                                 "AXI RLAST position is correct");
                    beat = beat + 1;
                end
                timeout = timeout + 1;
            end
            if (beat != sample_count)
                record_check(1'b0, "AXI data read burst did not complete");
            @(negedge aclk);
            data_rready = 1'b0;
        end
    endtask

    task automatic run_sequential_case;
        input integer sample_count;
        input integer read_backpressure;
        input [8*80-1:0] case_name;
        reg [31:0] status_value;
        begin
            $display("\n--- CASE: %0s ---", case_name);
            build_expected(sample_count);
            configure_fir(sample_count);
            send_data_burst(sample_count, 2'b00);
            receive_and_check_burst(sample_count, read_backpressure);
            axil_read(ADDR_STATUS, status_value, 2'b00);
            record_check(status_value[1] == 1'b1,
                         "DONE sticky status asserted after complete frame");
            record_check(irq_done == 1'b1,
                         "DONE interrupt asserted when enabled");
            axil_write(ADDR_STATUS, 32'h0000_0002, 4'b0001, 2'b00);
            record_check(irq_done == 1'b0,
                         "DONE interrupt clears through STATUS W1C");
        end
    endtask

    task automatic run_concurrent_case;
        input integer sample_count;
        input integer read_delay_cycles;
        input integer read_backpressure;
        input [8*80-1:0] case_name;
        begin
            $display("\n--- CASE: %0s ---", case_name);
            build_expected(sample_count);
            configure_fir(sample_count);
            fork
                begin
                    send_data_burst(sample_count, 2'b00);
                end
                begin
                    repeat (read_delay_cycles) @(posedge aclk);
                    receive_and_check_burst(sample_count,
                                            read_backpressure);
                end
            join
        end
    endtask

    task automatic test_disabled_write_deadlock;
        integer timeout;
        integer beat;
        reg aw_done;
        reg beat_done;
        begin
            $display("\n--- CASE: disabled FIR consumes write burst with SLVERR ---");
            apply_reset();
            @(negedge aclk);
            data_awaddr  = DATA_BASE;
            data_awlen   = 8'd3;
            data_awsize  = 3'd2;
            data_awburst = 2'b01;
            data_awvalid = 1'b1;
            aw_done = 1'b0;
            timeout = 0;
            while (!aw_done && timeout < 20) begin
                @(posedge aclk);
                if (data_awvalid && data_awready)
                    aw_done = 1'b1;
                @(negedge aclk);
                if (aw_done)
                    data_awvalid = 1'b0;
                timeout = timeout + 1;
            end
            record_check(aw_done,
                         "Disabled-write negative test accepted AW request");

            for (beat = 0; beat < 4; beat = beat + 1) begin
                data_wdata  = 32'h0000_1234 + beat;
                data_wstrb  = 4'b1111;
                data_wlast  = (beat == 3);
                data_wvalid = 1'b1;
                beat_done = 1'b0;
                timeout = 0;
                while (!beat_done && timeout < 20) begin
                    @(posedge aclk);
                    if (data_wvalid && data_wready)
                        beat_done = 1'b1;
                    timeout = timeout + 1;
                end
                record_check(beat_done,
                             "Disabled FIR consumed the expected W beat");
                if (beat != 3)
                    record_check(data_bvalid == 1'b0,
                                 "Disabled write did not issue an early B response");
                @(negedge aclk);
            end
            data_wvalid = 1'b0;
            data_wlast  = 1'b0;
            timeout = 0;
            while (!data_bvalid && timeout < 20) begin
                @(posedge aclk);
                timeout = timeout + 1;
            end
            record_check(data_bvalid && data_bresp == 2'b10,
                         "Disabled FIR returned bounded SLVERR response");
            record_check(dut.u_fir_data.fifo_count == 0 &&
                         !dut.fir_s_tvalid,
                         "Disabled FIR accepted no sample and produced no output");
            repeat (3) begin
                @(posedge aclk);
                record_check(data_bvalid && data_bresp == 2'b10,
                             "BVALID and BRESP remain stable under BREADY stall");
            end
            @(negedge aclk);
            data_bready = 1'b1;
            @(posedge aclk);
            @(negedge aclk);
            data_bready = 1'b0;
            apply_reset();
        end
    endtask

    task automatic test_clear_flushes_queued_results;
        integer index;
        integer timeout;
        begin
            $display("\n--- CASE: CTRL.CLR flushes pending FIR results ---");
            apply_reset();
            clear_models();
            coeff_model[0] = 32767;
            for (index = 0; index < 8; index = index + 1)
                sample_model[index] = 1000 + index;
            configure_fir(8);
            send_data_burst(8, 2'b00);
            timeout = 0;
            while (dut.u_fir_data.fifo_count != 8 && timeout < 100) begin
                @(posedge aclk);
                timeout = timeout + 1;
            end
            record_check(dut.u_fir_data.fifo_count == 8,
                         "Old results were queued before clear");

            axil_write(ADDR_CTRL, 32'h0000_0004, 4'b0001, 2'b00);
            repeat (2) @(posedge aclk);
            record_check(dut.u_fir_data.fifo_count == 0,
                         "CTRL.CLR removed all old FIFO entries");
            record_check(!dut.fir_m_tvalid,
                         "CTRL.CLR removed old core output state");

            clear_models();
            sample_model[0] = 1234;
            build_expected(1);
            configure_fir(1);
            send_data_burst(1, 2'b00);
            receive_and_check_burst(1, 1);
            record_check(dut.u_fir_data.fifo_count == 0,
                         "New run left no stale output in FIFO");
        end
    endtask

    task automatic test_write_error_drain_and_busy_clear;
        integer beat;
        integer timeout;
        reg aw_done;
        reg beat_done;
        reg [31:0] ctrl_value;
        begin
            $display("\n--- CASE: early WLAST, bad WSTRB and clear during active data write ---");
            apply_reset();
            clear_models();
            coeff_model[0] = 32767;
            configure_fir(4);

            @(negedge aclk);
            data_awaddr = DATA_BASE;
            data_awlen = 8'd3;
            data_awsize = 3'd2;
            data_awburst = 2'b01;
            data_awvalid = 1'b1;
            aw_done = 1'b0;
            timeout = 0;
            while (!aw_done && timeout < 30) begin
                @(posedge aclk);
                if (data_awvalid && data_awready)
                    aw_done = 1'b1;
                @(negedge aclk);
                if (aw_done)
                    data_awvalid = 1'b0;
                timeout = timeout + 1;
            end
            record_check(aw_done, "Four-beat data AW accepted");

            axil_write(ADDR_CTRL, 32'h0000_0004, 4'b0001, 2'b10);
            axil_read(ADDR_CTRL, ctrl_value, 2'b00);
            record_check(ctrl_value[0] == 1'b1,
                         "Rejected busy clear did not disable FIR");

            for (beat = 0; beat < 4; beat = beat + 1) begin
                @(negedge aclk);
                data_wdata = 32'd100 + beat;
                data_wstrb = (beat == 2) ? 4'b0000 : 4'b1111;
                data_wlast = (beat == 1) || (beat == 3);
                data_wvalid = 1'b1;
                beat_done = 1'b0;
                timeout = 0;
                while (!beat_done && timeout < 30) begin
                    @(posedge aclk);
                    if (data_wvalid && data_wready)
                        beat_done = 1'b1;
                    timeout = timeout + 1;
                end
                record_check(beat_done,
                             "Erroneous W beat was consumed without deadlock");
                if (beat != 3)
                    record_check(data_bvalid == 1'b0,
                                 "Early WLAST did not truncate the burst");
                @(negedge aclk);
                data_wvalid = 1'b0;
            end
            data_wlast = 1'b0;
            timeout = 0;
            while (!data_bvalid && timeout < 30) begin
                @(posedge aclk);
                timeout = timeout + 1;
            end
            record_check(data_bvalid && data_bresp == 2'b10,
                         "WLAST/WSTRB error returned one SLVERR response");
            repeat (2) begin
                @(posedge aclk);
                record_check(data_bvalid && data_bresp == 2'b10,
                             "Errored B response stayed stable while stalled");
            end
            @(negedge aclk);
            data_bready = 1'b1;
            @(posedge aclk);
            @(negedge aclk);
            data_bready = 1'b0;

            axil_write(ADDR_CTRL, 32'h0000_0004, 4'b0001, 2'b00);
            repeat (2) @(posedge aclk);
            record_check(dut.u_fir_data.fifo_count == 0,
                         "Clear succeeds after data transaction completes");
        end
    endtask

    task automatic issue_invalid_data_read;
        integer timeout;
        reg ar_done;
        begin
            @(negedge aclk);
            data_araddr  = DATA_BASE + 32'd4;
            data_arlen   = 8'd0;
            data_arsize  = 3'd2;
            data_arburst = 2'b01;
            data_arvalid = 1'b1;
            ar_done = 1'b0;
            timeout = 0;
            while (!ar_done && timeout < 50) begin
                @(posedge aclk);
                if (data_arvalid && data_arready)
                    ar_done = 1'b1;
                @(negedge aclk);
                if (ar_done)
                    data_arvalid = 1'b0;
                timeout = timeout + 1;
            end
            data_rready = 1'b1;
            timeout = 0;
            while (!data_rvalid && timeout < 50) begin
                @(posedge aclk);
                timeout = timeout + 1;
            end
            if (data_rvalid) begin
                record_check(data_rresp == 2'b10,
                             "Invalid data-window read returns SLVERR");
                @(posedge aclk);
            end else begin
                record_check(1'b0,
                             "Invalid data-window read response timeout");
            end
            @(negedge aclk);
            data_rready = 1'b0;
        end
    endtask

    task automatic test_fifo_full_illegal_read;
        integer index;
        integer timeout;
        integer count_before;
        begin
            $display("\n--- NEGATIVE CASE: invalid read while result FIFO is full ---");
            apply_reset();
            clear_models();
            coeff_model[0] = 32767;
            for (index = 0; index < FIFO_DEPTH + 8; index = index + 1)
                sample_model[index] = 100 + index;
            build_expected(FIFO_DEPTH + 8);
            configure_fir(FIFO_DEPTH + 8);

            fork : fifo_fill_group
                begin
                    send_data_burst(FIFO_DEPTH + 8, 2'b00);
                end
                begin
                    timeout = 0;
                    while ((dut.u_fir_data.fifo_count != FIFO_DEPTH) &&
                           timeout < 1000) begin
                        @(posedge aclk);
                        timeout = timeout + 1;
                    end
                    record_check(dut.u_fir_data.fifo_count == FIFO_DEPTH,
                                 "Result FIFO reached full state without overflow");

                    timeout = 0;
                    while (!(dut.fir_m_tvalid && !dut.fir_m_tready) &&
                           timeout < 1000) begin
                        @(posedge aclk);
                        timeout = timeout + 1;
                    end
                    record_check(dut.fir_m_tvalid && !dut.fir_m_tready,
                                 "FIR output is held under FIFO backpressure");
                    repeat (5) @(posedge aclk);
                    count_before = dut.u_fir_data.fifo_count;
                    record_check(count_before == FIFO_DEPTH,
                                 "Full FIFO count remains bounded during normal stall");

                    issue_invalid_data_read();
                    repeat (2) @(posedge aclk);
                    if (dut.u_fir_data.fifo_count > FIFO_DEPTH) begin
                        record_requirement_failure(
                            "invalid read handshake permits a push into an already-full result FIFO");
                    end else begin
                        record_check(1'b1,
                                     "Invalid read cannot create a full-FIFO overwrite");
                    end
                    // Drain all expected results after the illegal access.
                    // This catches silent overwrites even if fifo_count
                    // happens to return to a legal value later.
                    receive_and_check_burst(FIFO_DEPTH + 8, 1);
                end
            join
            record_check(dut.u_fir_data.fifo_count == 0,
                         "All FIFO results survived the illegal read");
            apply_reset();
        end
    endtask

    task automatic test_reset_interrupts_burst;
        integer timeout;
        reg aw_done;
        reg w_done;
        begin
            $display("\n--- CASE: reset aborts an active burst and removes old samples ---");
            apply_reset();
            clear_models();
            coeff_model[0] = 32767;
            configure_fir(4);

            @(negedge aclk);
            data_awaddr  = DATA_BASE;
            data_awlen   = 8'd3;
            data_awsize  = 3'd2;
            data_awburst = 2'b01;
            data_awvalid = 1'b1;
            aw_done = 1'b0;
            timeout = 0;
            while (!aw_done && timeout < 100) begin
                @(posedge aclk);
                if (data_awvalid && data_awready)
                    aw_done = 1'b1;
                @(negedge aclk);
                if (aw_done)
                    data_awvalid = 1'b0;
                timeout = timeout + 1;
            end
            record_check(aw_done, "Interrupted burst AW accepted");

            data_wdata  = 32'd1234;
            data_wstrb  = 4'b1111;
            data_wlast  = 1'b0;
            data_wvalid = 1'b1;
            w_done = 1'b0;
            timeout = 0;
            while (!w_done && timeout < 100) begin
                @(posedge aclk);
                if (data_wvalid && data_wready)
                    w_done = 1'b1;
                timeout = timeout + 1;
            end
            record_check(w_done, "First W beat accepted before reset");
            @(negedge aclk);
            data_wvalid = 1'b0;
            repeat (5) @(posedge aclk);
            record_check(dut.u_fir_data.fifo_count == 1 &&
                         dut.u_fir_data.write_active && !data_bvalid,
                         "Old result queued while four-beat write is unfinished");

            apply_reset();
            record_check(dut.u_fir_data.fifo_count == 0 &&
                         !dut.u_fir_data.write_active &&
                         !dut.u_fir_data.read_active &&
                         !data_bvalid && !data_rvalid,
                         "Reset aborts bus transaction and empties result FIFO");
            record_check(!dut.fir_m_tvalid && !irq_done && !irq_ovf,
                         "Reset clears pending core output and interrupt state");

            clear_models();
            sample_model[0] = 5678;
            run_sequential_case(1, 1,
                                "new zero-coefficient run after interrupted reset");
        end
    endtask

    task automatic test_csr_sample_strobes;
        begin
            $display("\n--- CASE: CSR DATA_IN byte-strobe validity ---");
            apply_reset();
            axil_write(ADDR_CTRL, 32'h0000_0001, 4'b0001, 2'b00);
            axil_write(ADDR_DATA_IN, 32'h0000_1234, 4'b0000, 2'b10);
            axil_write(ADDR_DATA_IN, 32'h0000_1234, 4'b0001, 2'b10);
            repeat (5) @(posedge aclk);
            record_check(dut.u_fir_data.fifo_count == 0,
                         "Invalid CSR strobes did not inject a sample");
            axil_write(ADDR_DATA_IN, 32'h0000_1234, 4'b0011, 2'b00);
            repeat (5) @(posedge aclk);
            record_check(dut.u_fir_data.fifo_count == 1,
                         "Valid two-byte CSR strobe injected one sample");
            apply_reset();
        end
    endtask

    // Protocol stability and sustained-throughput monitors.
    always @(posedge aclk) begin
        if (!aresetn) begin
            core_stall_previous <= 1'b0;
            core_stall_data <= 32'd0;
            axi_r_stall_previous <= 1'b0;
            axi_r_stall_data <= 32'd0;
            axi_r_stall_resp <= 2'd0;
            axi_r_stall_last <= 1'b0;
            current_input_run <= 0;
        end else begin
            if (core_stall_previous) begin
                if (!dut.fir_m_tvalid ||
                    (dut.fir_m_tdata !== core_stall_data)) begin
                    error_count = error_count + 1;
                    $display("[%0t] FAIL: FIR output changed or VALID dropped while stalled",
                             $time);
                end
            end
            core_stall_previous <= dut.fir_m_tvalid && !dut.fir_m_tready;
            core_stall_data <= dut.fir_m_tdata;
            if (dut.fir_m_tvalid && !dut.fir_m_tready)
                core_stall_cycles = core_stall_cycles + 1;

            if (axi_r_stall_previous) begin
                if (!data_rvalid || data_rdata !== axi_r_stall_data ||
                    data_rresp !== axi_r_stall_resp ||
                    data_rlast !== axi_r_stall_last) begin
                    error_count = error_count + 1;
                    $display("[%0t] FAIL: AXI R payload changed while RREADY was low",
                             $time);
                end
            end
            axi_r_stall_previous <= data_rvalid && !data_rready;
            axi_r_stall_data <= data_rdata;
            axi_r_stall_resp <= data_rresp;
            axi_r_stall_last <= data_rlast;
            if (data_rvalid && !data_rready)
                axi_r_stall_cycles = axi_r_stall_cycles + 1;

            if (dut.fir_s_tvalid && dut.fir_s_tready) begin
                current_input_run = current_input_run + 1;
                if (current_input_run > max_input_run)
                    max_input_run = current_input_run;
            end else begin
                current_input_run = 0;
            end
        end
    end

    integer index;
    reg [31:0] readback_value;
    initial begin
        aclk = 1'b0;
        aresetn = 1'b0;
        check_count = 0;
        error_count = 0;
        requirement_failure_count = 0;
        known_issue_count = 0;
        max_input_run = 0;
        current_input_run = 0;
        core_stall_cycles = 0;
        axi_r_stall_cycles = 0;
        random_seed = 32'h1a2b_3c4d;
        drive_idle();

        $display("============================================================");
        $display("FIR subsystem independent verification");
        $display("FIR RTL includes verified bus and FIFO boundary fixes");
        $display("============================================================");

        // Explicitly characterize the disabled-write corner case first.
        test_disabled_write_deadlock();
        test_csr_sample_strobes();

        // All-zero coefficients: arbitrary samples must produce exact zero.
        apply_reset();
        clear_models();
        for (index = 0; index < 12; index = index + 1)
            sample_model[index] = (($random(random_seed) % 30000));
        run_sequential_case(12, 1, "all-zero coefficients");
        for (index = 0; index < 12; index = index + 1)
            record_check(expected_model[index] == 0,
                         "Zero-coefficient reference output is exactly zero");

        // Unit coefficient and constant input.
        apply_reset();
        clear_models();
        coeff_model[0] = 32767;
        for (index = 0; index < 16; index = index + 1)
            sample_model[index] = 1000;
        run_sequential_case(16, 1, "unit coefficient with constant input");

        // Full 81-tap impulse response.  Reading concurrently prevents the
        // output FIFO capacity from hiding later taps.
        apply_reset();
        clear_models();
        for (index = 0; index < N_TAP; index = index + 1)
            coeff_model[index] = ((index * 37) % 2048) - 1024;
        sample_model[0] = 32767;
        for (index = 1; index < N_TAP; index = index + 1)
            sample_model[index] = 0;
        run_concurrent_case(N_TAP, 8, 1,
                            "81-tap impulse response and coefficient order");

        // Independent random-vector test.
        apply_reset();
        clear_models();
        for (index = 0; index < N_TAP; index = index + 1)
            coeff_model[index] = ($random(random_seed) % 1024);
        for (index = 0; index < 24; index = index + 1)
            sample_model[index] = ($random(random_seed) % 30000);
        run_sequential_case(24, 1, "random coefficients and random samples");

        // Fill the result FIFO before beginning reads.  This creates real
        // AXI-Stream backpressure and checks stable VALID/DATA behavior.
        apply_reset();
        clear_models();
        coeff_model[0] = 32767;
        for (index = 0; index < 48; index = index + 1)
            sample_model[index] = index * 97 - 2000;
        run_concurrent_case(48, 100, 1,
                            "sustained input and output backpressure");
        record_check(core_stall_cycles > 0,
                     "Output backpressure was actually exercised");
        record_check(max_input_run >= 16,
                     "FIR accepted at least 16 consecutive samples at one per cycle");

        // Clear and reload coefficients without a global reset.  The previous
        // result FIFO was drained by run_concurrent_case.
        clear_models();
        for (index = 0; index < 10; index = index + 1)
            sample_model[index] = 500 - index * 11;
        run_sequential_case(10, 1,
                            "clear state and reload all-zero coefficients");
        for (index = 0; index < 10; index = index + 1)
            record_check(expected_model[index] == 0,
                         "No stale sample remains after clear/reload");

        // Read back representative CSRs and coefficient storage.
        axil_read(ADDR_CTRL, readback_value, 2'b00);
        record_check(readback_value[0] == 1'b1,
                     "CTRL readback reports FIR enabled");
        axil_read(ADDR_COEFF0, readback_value, 2'b00);
        record_check(readback_value == 32'd0,
                     "Coefficient readback matches most recent zero reload");

        test_clear_flushes_queued_results();

        test_write_error_drain_and_busy_clear();

        // Characterize the full-FIFO/invalid-read corner case last because a
        // failing implementation can intentionally corrupt its internal count.
        test_fifo_full_illegal_read();

        test_reset_interrupts_burst();

        record_check(irq_ovf == 1'b0,
                     "Overflow interrupt remains inactive for legal Q15 range");
        record_check(axi_r_stall_cycles > 0,
                     "AXI read-channel backpressure was exercised");

        $display("\n============================================================");
        $display("FIR VERIFICATION SUMMARY");
        $display("Checks executed              : %0d", check_count);
        $display("Unexpected functional errors : %0d", error_count);
        $display("Requirement failures         : %0d",
                 requirement_failure_count);
        $display("Known issues observed         : %0d", known_issue_count);
        $display("Longest 1-sample/cycle run    : %0d", max_input_run);
        $display("Core output stall cycles      : %0d", core_stall_cycles);
        $display("AXI R stall cycles            : %0d", axi_r_stall_cycles);
        if (error_count == 0 && requirement_failure_count == 0) begin
            $display("FIR VALIDATION RESULT: PASS");
            $display("============================================================");
            $finish;
        end else begin
            $display("FIR VALIDATION RESULT: FAIL");
            $display("============================================================");
            $fatal(1, "FIR verification failed");
        end
    end

    initial begin
        #5000000;
        $fatal(1, "FIR VALIDATION RESULT: FAIL (global simulation timeout)");
    end

endmodule
