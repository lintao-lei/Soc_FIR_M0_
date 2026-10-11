`timescale 1ns/1ps

// Phase 4: local config registers -> burst DMA -> actual arbiter/interconnect/SRAM.
// The CPU AXI master below initializes and checks SRAM; control writes use
// the local register interface, not an AXI-MMIO slave (that is the next step).
module tb_dma_config_integration;
    localparam [31:0] SRC1 = 32'h2000_0020;
    localparam [31:0] DST1 = 32'h2000_0100;
    localparam [31:0] SRC2 = 32'h2000_0024;
    localparam [31:0] DST2 = 32'h2000_0104;
    localparam [31:0] WORD1 = 32'h1234_5678;
    localparam [31:0] WORD2 = 32'hA5A5_5A5A;
    localparam [31:0] SRC4  = 32'h2000_0200;
    localparam [31:0] DST4  = 32'h2000_0400;
    localparam [31:0] SRC8  = 32'h2000_0600;
    localparam [31:0] DST8  = 32'h2000_0700;
    localparam [31:0] SRC16 = 32'h2000_0800;
    localparam [31:0] DST16 = 32'h2000_0C00;
    localparam [31:0] SRC20 = 32'h2000_1400;
    localparam [31:0] DST20 = 32'h2000_1800;
    localparam [31:0] SRC_PAGE = 32'h2000_1FFC;
    localparam [31:0] DST_PAGE = 32'h2000_2FF8;
    localparam [31:0] SRC_FAULT = 32'h2000_3400;
    localparam [31:0] DST_FAULT = 32'h2000_3800;
    localparam [31:0] SRC_RESET = 32'h2000_3C00;
    localparam [31:0] DST_RESET = 32'h2000_4000;
    localparam [31:0] SRC_EDGE = 32'h2000_FFFC;
    localparam [31:0] DST_EDGE = 32'h2000_1000;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg reset_n = 1'b0;

    // Virtual CPU AXI master, driven by tasks below.
    reg  [31:0] cpu_araddr = 32'd0;
    reg  [7:0]  cpu_arlen = 8'd0;
    reg  [2:0]  cpu_arsize = 3'b010;
    reg  [1:0]  cpu_arburst = 2'b01;
    reg         cpu_arvalid = 1'b0;
    wire        cpu_arready;
    wire [31:0] cpu_rdata;
    wire [1:0]  cpu_rresp;
    wire        cpu_rlast;
    wire        cpu_rvalid;
    reg         cpu_rready = 1'b0;
    reg  [31:0] cpu_awaddr = 32'd0;
    reg  [7:0]  cpu_awlen = 8'd0;
    reg  [2:0]  cpu_awsize = 3'b010;
    reg  [1:0]  cpu_awburst = 2'b01;
    reg         cpu_awvalid = 1'b0;
    wire        cpu_awready;
    reg  [31:0] cpu_wdata = 32'd0;
    reg  [3:0]  cpu_wstrb = 4'b1111;
    reg         cpu_wlast = 1'b1;
    reg         cpu_wvalid = 1'b0;
    wire        cpu_wready;
    wire [1:0]  cpu_bresp;
    wire        cpu_bvalid;
    reg         cpu_bready = 1'b0;

    // DMA AXI master. These names deliberately match arbiter's dma_* ports.
    reg         cfg_wr_en = 1'b0;
    reg  [11:0] cfg_wr_offset = 12'd0;
    reg  [31:0] cfg_wr_data = 32'd0;
    reg  [11:0] cfg_rd_offset = 12'd0;
    wire [31:0] cfg_rd_data;
    wire        dma_busy, dma_done, dma_error;
    wire [31:0] dma_araddr;
    wire [7:0]  dma_arlen;
    wire [2:0]  dma_arsize;
    wire [1:0]  dma_arburst;
    wire        dma_arvalid, dma_arready;
    wire [31:0] dma_rdata;
    wire [1:0]  dma_rresp;
    wire        dma_rlast, dma_rvalid, dma_rready;
    wire [31:0] dma_awaddr;
    wire [7:0]  dma_awlen;
    wire [2:0]  dma_awsize;
    wire [1:0]  dma_awburst;
    wire        dma_awvalid, dma_awready;
    wire [31:0] dma_wdata;
    wire [3:0]  dma_wstrb;
    wire        dma_wlast, dma_wvalid, dma_wready;
    wire [1:0]  dma_bresp;
    wire        dma_bvalid, dma_bready;

    // Reproducible pseudo-random backpressure at the DMA/arbiter boundary.
    // Gate both sides of a handshake: the arbiter must not consume a beat
    // while the DMA believes READY/VALID was low.
    reg stall_enable = 1'b0;
    reg [15:0] stall_lfsr = 16'hACE1;
    // Force the first AR of each stalled job to wait two clocks. The
    // remaining stalls are pseudo-random, but coverage cannot depend on luck.
    reg [1:0] forced_ar_wait = 2'd0;
    wire stall_ar = stall_enable &&
                    ((forced_ar_wait < 2'd2) ||
                     (stall_lfsr[0] && stall_lfsr[3]));
    wire stall_aw = stall_enable && stall_lfsr[1] && stall_lfsr[4];
    wire stall_w  = stall_enable && stall_lfsr[2];
    wire stall_r  = stall_enable && stall_lfsr[5];
    wire stall_b  = stall_enable && stall_lfsr[6];
    wire arb_dma_arvalid = dma_arvalid && !stall_ar;
    wire arb_dma_awvalid = dma_awvalid && !stall_aw;
    wire arb_dma_wvalid  = dma_wvalid  && !stall_w;
    wire arb_dma_rready  = dma_rready  && !stall_r;
    wire arb_dma_bready  = dma_bready  && !stall_b;
    wire raw_dma_arready, raw_dma_awready, raw_dma_wready;
    wire raw_dma_rvalid, raw_dma_bvalid;
    wire [1:0] raw_dma_rresp;
    assign dma_arready = raw_dma_arready && !stall_ar;
    assign dma_awready = raw_dma_awready && !stall_aw;
    assign dma_wready  = raw_dma_wready  && !stall_w;
    assign dma_rvalid  = raw_dma_rvalid  && !stall_r;
    assign dma_bvalid  = raw_dma_bvalid  && !stall_b;

    // Inject one SLVERR on read beat 1 of a mapped four-beat burst. This
    // tests that the DMA drains the remaining R beats and never starts AW.
    reg fault_enable = 1'b0;
    integer fault_rbeat_count = 0;
    assign dma_rresp = (fault_enable && fault_rbeat_count == 1 && dma_rvalid)
                     ? 2'b10 : raw_dma_rresp;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            stall_lfsr <= 16'hACE1;
            forced_ar_wait <= 2'd0;
        end else begin
            stall_lfsr <= {stall_lfsr[14:0],
                            stall_lfsr[15] ^ stall_lfsr[13] ^
                            stall_lfsr[12] ^ stall_lfsr[10]};
            if (!stall_enable) forced_ar_wait <= 2'd0;
            else if (dma_arvalid && forced_ar_wait < 2'd2)
                forced_ar_wait <= forced_ar_wait + 2'd1;
        end
    end

    // One AXI master interface from arbiter to the real interconnect.
    wire [31:0] m_araddr;
    wire [7:0]  m_arlen;
    wire [2:0]  m_arsize;
    wire [1:0]  m_arburst;
    wire        m_arvalid, m_arready;
    wire [31:0] m_rdata;
    wire [1:0]  m_rresp;
    wire        m_rlast, m_rvalid, m_rready;
    wire [31:0] m_awaddr;
    wire [7:0]  m_awlen;
    wire [2:0]  m_awsize;
    wire [1:0]  m_awburst;
    wire        m_awvalid, m_awready;
    wire [31:0] m_wdata;
    wire [3:0]  m_wstrb;
    wire        m_wlast, m_wvalid, m_wready;
    wire [1:0]  m_bresp;
    wire        m_bvalid, m_bready;
    wire        decode_error_seen, fir_irq_done, fir_irq_ovf;

    dma_configured_core u_dma (
        .clk(clk), .reset_n(reset_n),
        .wr_en(cfg_wr_en), .wr_offset(cfg_wr_offset),
        .wr_data(cfg_wr_data), .rd_offset(cfg_rd_offset),
        .rd_data(cfg_rd_data),
        .busy(dma_busy), .done(dma_done), .error(dma_error),
        .m_araddr(dma_araddr), .m_arlen(dma_arlen),
        .m_arsize(dma_arsize), .m_arburst(dma_arburst),
        .m_arvalid(dma_arvalid), .m_arready(dma_arready),
        .m_rdata(dma_rdata), .m_rresp(dma_rresp),
        .m_rlast(dma_rlast), .m_rvalid(dma_rvalid),
        .m_rready(dma_rready),
        .m_awaddr(dma_awaddr), .m_awlen(dma_awlen),
        .m_awsize(dma_awsize), .m_awburst(dma_awburst),
        .m_awvalid(dma_awvalid), .m_awready(dma_awready),
        .m_wdata(dma_wdata), .m_wstrb(dma_wstrb),
        .m_wlast(dma_wlast), .m_wvalid(dma_wvalid),
        .m_wready(dma_wready),
        .m_bresp(dma_bresp), .m_bvalid(dma_bvalid),
        .m_bready(dma_bready)
    );

    arbiter u_arbiter (
        .dma_arvalid(arb_dma_arvalid), .dma_arready(raw_dma_arready),
        .dma_awvalid(arb_dma_awvalid), .dma_awready(raw_dma_awready),
        .dma_wvalid(arb_dma_wvalid), .dma_wready(raw_dma_wready),
        .dma_rvalid(raw_dma_rvalid), .dma_rready(arb_dma_rready),
        .dma_rresp(raw_dma_rresp),
        .dma_bvalid(raw_dma_bvalid), .dma_bready(arb_dma_bready),
        .*
    );

    axi_interconnect_shell u_interconnect (
        .clk(clk), .reset_n(reset_n),
        .s_awaddr(m_awaddr), .s_awlen(m_awlen),
        .s_awsize(m_awsize), .s_awburst(m_awburst),
        .s_awvalid(m_awvalid), .s_awready(m_awready),
        .s_wdata(m_wdata), .s_wstrb(m_wstrb),
        .s_wlast(m_wlast), .s_wvalid(m_wvalid),
        .s_wready(m_wready),
        .s_bresp(m_bresp), .s_bvalid(m_bvalid), .s_bready(m_bready),
        .s_araddr(m_araddr), .s_arlen(m_arlen),
        .s_arsize(m_arsize), .s_arburst(m_arburst),
        .s_arvalid(m_arvalid), .s_arready(m_arready),
        .s_rdata(m_rdata), .s_rresp(m_rresp),
        .s_rlast(m_rlast), .s_rvalid(m_rvalid), .s_rready(m_rready),
        .error_seen(decode_error_seen),
        .fir_irq_done(fir_irq_done), .fir_irq_ovf(fir_irq_ovf)
    );

    integer checks = 0;
    integer dma_ar_count = 0, dma_r_count = 0;
    integer dma_aw_count = 0, dma_w_count = 0, dma_b_count = 0;
    integer dma_done_count = 0;
    reg cpu_read_inflight = 1'b0;
    reg dma_write_inflight = 1'b0;
    reg dma_waited_for_cpu = 1'b0;
    reg cpu_waited_for_dma = 1'b0;
    reg seq_track = 1'b0;
    reg allow_dma_read_error = 1'b0;
    integer dma_read_error_count = 0;
    reg [31:0] seq_src_base = 32'd0;
    reg [31:0] seq_dst_base = 32'd0;
    integer seq_total_words = 0;
    integer seq_ar_seen = 0, seq_r_seen = 0;
    integer seq_aw_seen = 0, seq_w_seen = 0, seq_b_seen = 0;
    integer seq_ar_words = 0, seq_aw_words = 0;
    integer seq_r_burst_words = 0, seq_w_burst_words = 0;
    integer seq_r_beat = 0, seq_w_beat = 0;
    integer stall_ar_count = 0, stall_aw_count = 0;
    integer stall_r_count = 0, stall_w_count = 0, stall_b_count = 0;

    function automatic [31:0] sample_value(input integer index);
        sample_value = 32'h5A00_0000 ^ (32'h0102_0304 * index);
    endfunction

    function automatic integer expected_burst_words(
        input [31:0] source_address,
        input [31:0] destination_address,
        input integer words_left
    );
        integer n, source_room, destination_room;
        begin
            n = (words_left > 16) ? 16 : words_left;
            source_room = (4096 - source_address[11:0]) / 4;
            destination_room = (4096 - destination_address[11:0]) / 4;
            if (n > source_room) n = source_room;
            if (n > destination_room) n = destination_room;
            expected_burst_words = n;
        end
    endfunction

    function automatic integer expected_burst_count(
        input [31:0] source_address,
        input [31:0] destination_address,
        input integer words
    );
        integer offset, count;
        begin
            offset = 0;
            count = 0;
            while (offset < words) begin
                offset = offset + expected_burst_words(
                    source_address + offset * 4,
                    destination_address + offset * 4, words - offset);
                count = count + 1;
            end
            expected_burst_count = count;
        end
    endfunction

    task automatic check(input bit condition, input string description);
        begin
            checks = checks + 1;
            if (!condition)
                $fatal(1, "CHECK %0d FAIL: %s (time=%0t)",
                       checks, description, $time);
        end
    endtask

    task automatic cfg_write(input [11:0] offset,
                             input [31:0] value);
        begin
            @(negedge clk);
            cfg_wr_offset = offset;
            cfg_wr_data = value;
            cfg_wr_en = 1'b1;
            @(negedge clk);
            cfg_wr_en = 1'b0;
        end
    endtask

    task automatic cfg_read_expect(input [11:0] offset,
                                   input [31:0] expected);
        begin
            @(negedge clk);
            cfg_rd_offset = offset;
            #1;
            check(cfg_rd_data === expected, "configuration register readback");
        end
    endtask

    task automatic cfg_launch(input [31:0] source_base,
                              input [31:0] destination_base,
                              input [15:0] words);
        begin
            cfg_write(12'h000, source_base);
            cfg_write(12'h004, destination_base);
            cfg_write(12'h008, {16'd0, words});
            cfg_read_expect(12'h000, source_base);
            cfg_read_expect(12'h004, destination_base);
            cfg_read_expect(12'h008, {16'd0, words});
            cfg_write(12'h00C, 32'd1);
            // Give dma_test one clock to sample the registered start pulse.
            @(negedge clk);
        end
    endtask

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            dma_ar_count <= 0;
            dma_r_count <= 0;
            dma_aw_count <= 0;
            dma_w_count <= 0;
            dma_b_count <= 0;
            dma_done_count <= 0;
            cpu_read_inflight <= 1'b0;
            dma_write_inflight <= 1'b0;
            dma_waited_for_cpu <= 1'b0;
            cpu_waited_for_dma <= 1'b0;
            seq_ar_seen <= 0;
            seq_r_seen <= 0;
            seq_aw_seen <= 0;
            seq_w_seen <= 0;
            seq_b_seen <= 0;
            seq_ar_words <= 0;
            seq_aw_words <= 0;
            seq_r_burst_words <= 0;
            seq_w_burst_words <= 0;
            seq_r_beat <= 0;
            seq_w_beat <= 0;
            dma_read_error_count <= 0;
            fault_rbeat_count <= 0;
            stall_ar_count <= 0;
            stall_aw_count <= 0;
            stall_r_count <= 0;
            stall_w_count <= 0;
            stall_b_count <= 0;
        end else begin
            if (cpu_arvalid && cpu_arready) cpu_read_inflight <= 1'b1;
            if (cpu_rvalid && cpu_rready && cpu_rlast)
                cpu_read_inflight <= 1'b0;
            if (dma_awvalid && dma_awready)
                dma_write_inflight <= 1'b1;
            if (dma_bvalid && dma_bready)
                dma_write_inflight <= 1'b0;
            if (dma_arvalid && !dma_arready && cpu_read_inflight)
                dma_waited_for_cpu <= 1'b1;
            if (cpu_arvalid && !cpu_arready && dma_write_inflight)
                cpu_waited_for_dma <= 1'b1;

            if (stall_enable && dma_arvalid && !dma_arready)
                stall_ar_count <= stall_ar_count + 1;
            if (stall_enable && dma_awvalid && !dma_awready)
                stall_aw_count <= stall_aw_count + 1;
            if (stall_enable && raw_dma_rvalid && !arb_dma_rready)
                stall_r_count <= stall_r_count + 1;
            if (stall_enable && dma_wvalid && !dma_wready)
                stall_w_count <= stall_w_count + 1;
            if (stall_enable && raw_dma_bvalid && !arb_dma_bready)
                stall_b_count <= stall_b_count + 1;

            if (dma_arvalid && dma_arready) begin
                dma_ar_count <= dma_ar_count + 1;
                if (seq_track) begin
                    check(dma_araddr === seq_src_base + (seq_ar_words * 4),
                          "AR address is the next source burst address");
                    check(dma_arlen + 1 == expected_burst_words(
                          seq_src_base + (seq_ar_words * 4),
                          seq_dst_base + (seq_ar_words * 4),
                          seq_total_words - seq_ar_words),
                          "ARLEN matches remaining words and both 4 KiB limits");
                    check(dma_arsize === 3'b010 && dma_arburst === 2'b01,
                          "AR is aligned 32-bit INCR");
                    check(dma_araddr[11:0] + ((dma_arlen + 1) * 4) <= 4096,
                          "AR burst does not cross 4 KiB");
                    seq_ar_words <= seq_ar_words + dma_arlen + 1;
                    seq_r_burst_words <= dma_arlen + 1;
                    seq_r_beat <= 0;
                    seq_ar_seen <= seq_ar_seen + 1;
                end
            end
            if (dma_rvalid && dma_rready) begin
                dma_r_count <= dma_r_count + 1;
                if (fault_enable) fault_rbeat_count <= fault_rbeat_count + 1;
                if (dma_rresp !== 2'b00) begin
                    if (!allow_dma_read_error ||
                        (dma_rresp !== 2'b11 && dma_rresp !== 2'b10))
                        $fatal(1, "Unexpected DMA read response %b", dma_rresp);
                    dma_read_error_count <= dma_read_error_count + 1;
                end
                if (seq_track) begin
                    check(dma_rresp === 2'b00,
                          "successful burst RRESP is OKAY");
                    check(dma_rlast ===
                          (seq_r_beat == seq_r_burst_words - 1),
                          "RLAST occurs only on the final read beat");
                    check(dma_rdata === sample_value(seq_r_seen),
                          "each R beat matches the source word");
                    seq_r_seen <= seq_r_seen + 1;
                    seq_r_beat <= seq_r_beat + 1;
                end
            end
            if (dma_awvalid && dma_awready) begin
                dma_aw_count <= dma_aw_count + 1;
                if (seq_track) begin
                    check(dma_awaddr === seq_dst_base + (seq_aw_words * 4),
                          "AW address is the next destination burst address");
                    check(dma_awlen + 1 == expected_burst_words(
                          seq_src_base + (seq_aw_words * 4),
                          seq_dst_base + (seq_aw_words * 4),
                          seq_total_words - seq_aw_words),
                          "AWLEN matches corresponding AR burst");
                    check(dma_awsize === 3'b010 && dma_awburst === 2'b01,
                          "AW is aligned 32-bit INCR");
                    check(dma_awaddr[11:0] + ((dma_awlen + 1) * 4) <= 4096,
                          "AW burst does not cross 4 KiB");
                    seq_aw_words <= seq_aw_words + dma_awlen + 1;
                    seq_w_burst_words <= dma_awlen + 1;
                    seq_w_beat <= 0;
                    seq_aw_seen <= seq_aw_seen + 1;
                end
            end
            if (dma_wvalid && dma_wready) begin
                dma_w_count <= dma_w_count + 1;
                check(dma_wstrb === 4'b1111, "DMA writes all four byte lanes");
                if (seq_track) begin
                    check(dma_wlast ===
                          (seq_w_beat == seq_w_burst_words - 1),
                          "WLAST occurs only on the final write beat");
                    check(dma_wdata === sample_value(seq_w_seen),
                          "each W beat matches the corresponding R beat");
                    seq_w_seen <= seq_w_seen + 1;
                    seq_w_beat <= seq_w_beat + 1;
                end
            end
            if (dma_bvalid && dma_bready) begin
                dma_b_count <= dma_b_count + 1;
                if (dma_bresp !== 2'b00)
                    $fatal(1, "DMA write returned non-OKAY BRESP");
                if (seq_track) begin
                    check(seq_w_beat == seq_w_burst_words,
                          "one B arrives only after all W beats");
                    seq_b_seen <= seq_b_seen + 1;
                end
            end
            if (dma_done) dma_done_count <= dma_done_count + 1;
        end
    end

    // AXI payload must remain stable while VALID is asserted and READY is 0.
    reg held_ar = 1'b0, held_aw = 1'b0, held_w = 1'b0;
    reg held_r = 1'b0, held_b = 1'b0;
    reg [31:0] held_araddr, held_awaddr, held_wdata, held_rdata;
    reg [7:0] held_arlen, held_awlen;
    reg [2:0] held_arsize, held_awsize;
    reg [1:0] held_arburst, held_awburst;
    reg [3:0] held_wstrb;
    reg held_wlast, held_rlast;
    reg [1:0] held_rresp, held_bresp;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            held_ar <= 1'b0; held_aw <= 1'b0; held_w <= 1'b0;
            held_r <= 1'b0; held_b <= 1'b0;
        end else begin
            if (held_ar)
                check(dma_arvalid && dma_araddr === held_araddr &&
                      dma_arlen === held_arlen && dma_arsize === held_arsize &&
                      dma_arburst === held_arburst, "AR stable under stall");
            held_ar <= dma_arvalid && !dma_arready;
            if (dma_arvalid && !dma_arready) begin
                held_araddr <= dma_araddr; held_arlen <= dma_arlen;
                held_arsize <= dma_arsize; held_arburst <= dma_arburst;
            end

            if (held_aw)
                check(dma_awvalid && dma_awaddr === held_awaddr &&
                      dma_awlen === held_awlen && dma_awsize === held_awsize &&
                      dma_awburst === held_awburst, "AW stable under stall");
            held_aw <= dma_awvalid && !dma_awready;
            if (dma_awvalid && !dma_awready) begin
                held_awaddr <= dma_awaddr; held_awlen <= dma_awlen;
                held_awsize <= dma_awsize; held_awburst <= dma_awburst;
            end

            if (held_w)
                check(dma_wvalid && dma_wdata === held_wdata &&
                      dma_wstrb === held_wstrb && dma_wlast === held_wlast,
                      "W stable under stall");
            held_w <= dma_wvalid && !dma_wready;
            if (dma_wvalid && !dma_wready) begin
                held_wdata <= dma_wdata; held_wstrb <= dma_wstrb;
                held_wlast <= dma_wlast;
            end

            if (held_r)
                check(raw_dma_rvalid && dma_rdata === held_rdata &&
                      raw_dma_rresp === held_rresp && dma_rlast === held_rlast,
                      "R stable under stall");
            held_r <= raw_dma_rvalid && !arb_dma_rready;
            if (raw_dma_rvalid && !arb_dma_rready) begin
                held_rdata <= dma_rdata; held_rresp <= raw_dma_rresp;
                held_rlast <= dma_rlast;
            end

            if (held_b)
                check(raw_dma_bvalid && dma_bresp === held_bresp,
                      "B stable under stall");
            held_b <= raw_dma_bvalid && !arb_dma_bready;
            if (raw_dma_bvalid && !arb_dma_bready)
                held_bresp <= dma_bresp;
        end
    end

    // Only one master is accepted per clock, including across read/write.
    always @(posedge clk) begin
        if (reset_n &&
            ((cpu_arvalid && cpu_arready) +
             (cpu_awvalid && cpu_awready) +
             (dma_arvalid && dma_arready) +
             (dma_awvalid && dma_awready) > 1))
            $fatal(1, "Arbiter accepted two new transactions at once");
    end

    task automatic cpu_write_word(input [31:0] address,
                                  input [31:0] value);
        begin
            @(negedge clk);
            cpu_awaddr = address;
            cpu_awvalid = 1'b1;
            do @(posedge clk); while (!(cpu_awvalid && cpu_awready));
            @(negedge clk);
            cpu_awvalid = 1'b0;
            cpu_wdata = value;
            cpu_wstrb = 4'b1111;
            cpu_wlast = 1'b1;
            cpu_wvalid = 1'b1;
            do @(posedge clk); while (!(cpu_wvalid && cpu_wready));
            @(negedge clk);
            cpu_wvalid = 1'b0;
            repeat (2) @(negedge clk); // deliberate BREADY backpressure
            check(cpu_bvalid, "CPU BVALID held while BREADY=0");
            cpu_bready = 1'b1;
            do @(posedge clk); while (!(cpu_bvalid && cpu_bready));
            check(cpu_bresp === 2'b00, "CPU write got OKAY BRESP");
            @(negedge clk);
            cpu_bready = 1'b0;
            $display("[%0t] CPU WRITE 0x%08h = 0x%08h", $time,
                     address, value);
        end
    endtask

    task automatic cpu_read_expect(input [31:0] address,
                                   input [31:0] expected,
                                   input integer stall_cycles);
        begin
            @(negedge clk);
            cpu_araddr = address;
            cpu_arvalid = 1'b1;
            do @(posedge clk); while (!(cpu_arvalid && cpu_arready));
            @(negedge clk);
            cpu_arvalid = 1'b0;
            repeat (stall_cycles) @(negedge clk);
            cpu_rready = 1'b1;
            do @(posedge clk); while (!(cpu_rvalid && cpu_rready));
            check(cpu_rresp === 2'b00 && cpu_rlast,
                  "CPU single-beat read got OKAY and RLAST");
            check(cpu_rdata === expected,
                  "CPU read data matches expected SRAM value");
            @(negedge clk);
            cpu_rready = 1'b0;
            $display("[%0t] CPU READ  0x%08h = 0x%08h", $time,
                     address, expected);
        end
    endtask

    task automatic copy_and_check_words(input [31:0] source_base,
                                         input [31:0] destination_base,
                                         input integer words,
                                         input bit use_stalls);
        integer i;
        integer ar_before, r_before, aw_before, w_before, b_before;
        integer done_before;
        integer burst_count;
        integer r_stalls_before, w_stalls_before;
        begin
            burst_count = expected_burst_count(source_base,
                                               destination_base, words);
            $display("[TB] Copy %0d words in %0d burst(s): 0x%08h -> 0x%08h",
                     words, burst_count, source_base, destination_base);
            for (i = 0; i < words; i = i + 1) begin
                cpu_write_word(source_base + (i * 4), sample_value(i));
                cpu_write_word(destination_base + (i * 4),
                               32'hDEAD_0000 + i);
            end
            cpu_write_word(destination_base + (words * 4), 32'hFACE_B00C);

            ar_before = dma_ar_count;
            r_before = dma_r_count;
            aw_before = dma_aw_count;
            w_before = dma_w_count;
            b_before = dma_b_count;
            done_before = dma_done_count;
            r_stalls_before = stall_r_count;
            w_stalls_before = stall_w_count;
            seq_src_base = source_base;
            seq_dst_base = destination_base;
            seq_total_words = words;
            seq_ar_seen = 0;
            seq_r_seen = 0;
            seq_aw_seen = 0;
            seq_w_seen = 0;
            seq_b_seen = 0;
            seq_ar_words = 0;
            seq_aw_words = 0;
            seq_r_burst_words = 0;
            seq_w_burst_words = 0;
            seq_r_beat = 0;
            seq_w_beat = 0;
            seq_track = 1'b1;
            stall_enable = use_stalls;

            cfg_launch(source_base, destination_base, words[15:0]);
            cfg_read_expect(12'h010, 32'h0000_0001);
            // A second START during BUSY must be ignored, not queued.
            cfg_write(12'h00C, 32'd1);
            // Reprogram configuration while active: the DMA must continue
            // using the values it latched at start, not these new values.
            if (words >= 8) begin
                cfg_write(12'h000, 32'hDEAD_BEEF);
                cfg_write(12'h004, 32'hCAFE_BABE);
                cfg_write(12'h008, 32'd1);
            end

            do @(posedge clk); while (!dma_done);
            check(!dma_error, "multi-word DMA job finished without error");
            @(negedge clk);
            stall_enable = 1'b0;
            seq_track = 1'b0;
            check(seq_ar_seen == burst_count && seq_r_seen == words &&
                  seq_aw_seen == burst_count && seq_w_seen == words &&
                  seq_b_seen == burst_count,
                  "one AR/AW/B per burst and one R/W per word");
            check(seq_ar_words == words && seq_aw_words == words,
                  "burst lengths cover all requested words exactly once");
            check(dma_ar_count - ar_before == burst_count &&
                  dma_r_count - r_before == words &&
                  dma_aw_count - aw_before == burst_count &&
                  dma_w_count - w_before == words &&
                  dma_b_count - b_before == burst_count,
                  "no AXI burst or data beat was lost or repeated");
            check(dma_done_count - done_before == 1,
                  "one done pulse for the whole multi-word job");
            cfg_read_expect(12'h010, 32'h0000_0002);
            cfg_read_expect(12'h010, 32'h0000_0002);
            if (use_stalls) begin
                check(stall_r_count > r_stalls_before,
                      "read response path really exercised backpressure");
                check(stall_w_count > w_stalls_before,
                      "write data path really exercised backpressure");
            end

            for (i = 0; i < words; i = i + 1)
                cpu_read_expect(destination_base + (i * 4),
                                sample_value(i), i % 3);
            cpu_read_expect(destination_base + (words * 4),
                            32'hFACE_B00C, 0);
            cpu_read_expect(source_base, sample_value(0), 0);
            cpu_read_expect(source_base + ((words - 1) * 4),
                            sample_value(words - 1), 0);
        end
    endtask

    initial begin
        #100000;
        $fatal(1, "TEST FAIL: 100 us timeout");
    end

    initial begin
        $display("[TB] Config registers -> DMA -> arbiter -> AXI interconnect -> SRAM");
        repeat (5) @(negedge clk);
        reset_n = 1'b1;
        cfg_read_expect(12'h010, 32'd0);

        // Prepare source, destination and adjacent word using virtual CPU.
        cpu_write_word(SRC1, WORD1);
        cpu_write_word(DST1, 32'hDEAD_BEEF);
        cpu_write_word(SRC2, WORD2);
        cpu_write_word(DST2, 32'hFACE_CAFE);
        cpu_write_word(32'h0000_0000, 32'hCAFE_BABE); // code SRAM guard
        cpu_read_expect(SRC1, WORD1, 0);

        // Test 1: CPU read wins first. DMA must hold AR until CPU's final R
        // handshake; then DMA copies A to B through the *real* data SRAM.
        $display("[TB] Test 1: CPU read holds bus while DMA requests AR");
        fork
            cpu_read_expect(SRC1, WORD1, 20);
            begin
                cfg_launch(SRC1, DST1, 16'd1);
            end
        join
        do @(posedge clk); while (!dma_done);
        check(!dma_error, "DMA copy 1 completed without error");
        @(negedge clk);
        cfg_read_expect(12'h010, 32'h0000_0002);
        check(dma_waited_for_cpu, "DMA AR really waited behind CPU read");
        cpu_read_expect(DST1, WORD1, 2);
        check(u_interconnect.u_two_sram.u_data_sram
              .u_simple_sram_core.memory[DST1[15:2]] === WORD1,
              "actual data SRAM destination word was changed");
        cpu_read_expect(32'h0000_0000, 32'hCAFE_BABE, 0);

        // Test 2: issue CPU read immediately after DMA AW handshake. The
        // CPU must wait until DMA's B response, then see the new value.
        $display("[TB] Test 2: CPU AR waits behind DMA write transaction");
        cfg_launch(SRC2, DST2, 16'd1);
        do @(posedge clk); while (!(dma_awvalid && dma_awready));
        @(negedge clk);
        cpu_araddr = DST2;
        cpu_arvalid = 1'b1;
        do @(posedge clk); while (!(cpu_arvalid && cpu_arready));
        @(negedge clk);
        cpu_arvalid = 1'b0;
        cpu_rready = 1'b1;
        do @(posedge clk); while (!(cpu_rvalid && cpu_rready));
        check(cpu_rresp === 2'b00 && cpu_rlast,
              "CPU read after DMA write got OKAY and RLAST");
        check(cpu_rdata === WORD2,
              "CPU saw copied value, not old destination value");
        @(negedge clk);
        cpu_rready = 1'b0;

        check(cpu_waited_for_dma, "CPU AR really waited behind DMA write");
        check(dma_done_count == 2 && !dma_error,
              "both DMA jobs completed without error");
        check(dma_ar_count == 2 && dma_r_count == 2 &&
              dma_aw_count == 2 && dma_w_count == 2 && dma_b_count == 2,
              "each DMA job used exactly one AR/R/AW/W/B handshake");
        check(!decode_error_seen, "no AXI address decode error");
        cpu_read_expect(SRC1, WORD1, 0);
        cpu_read_expect(SRC2, WORD2, 0);
        cpu_read_expect(DST1, WORD1, 0);
        cpu_read_expect(DST2, WORD2, 0);

        // Zero length must fail locally without touching the AXI bus.
        $display("[TB] Reject zero-word request");
        begin : zero_length_test
            integer ar_before, aw_before, done_before;
            ar_before = dma_ar_count;
            aw_before = dma_aw_count;
            done_before = dma_done_count;
            cfg_launch(SRC4, DST4, 16'd0);
            check(dma_done && dma_error && !dma_busy,
                  "zero-word request produces done+error");
            @(negedge clk);
            cfg_read_expect(12'h010, 32'h0000_0006);
            check(dma_ar_count == ar_before && dma_aw_count == aw_before,
                  "zero-word request issued no AXI address");
            check(dma_done_count == done_before + 1,
                  "zero-word request produced one done pulse");
        end

        copy_and_check_words(SRC4, DST4, 4, 1'b0);
        copy_and_check_words(SRC8, DST8, 8, 1'b1);
        copy_and_check_words(SRC16, DST16, 16, 1'b1);
        copy_and_check_words(SRC20, DST20, 20, 1'b1);
        // Source has room for 1 beat, destination for 2. The first two
        // bursts must each be one beat, followed by 16 and then 2 beats.
        copy_and_check_words(SRC_PAGE, DST_PAGE, 20, 1'b1);
        check(!decode_error_seen, "no AXI address decode error");
        $display("[TB] Stall counts AR=%0d AW=%0d R=%0d W=%0d B=%0d",
                 stall_ar_count, stall_aw_count, stall_r_count,
                 stall_w_count, stall_b_count);
        check(stall_ar_count > 0 && stall_aw_count > 0 &&
              stall_r_count > 0 && stall_w_count > 0 &&
              stall_b_count > 0,
              "all five AXI channels actually experienced backpressure");

        // Error on R beat 1 of a mapped 4-beat burst. The DMA must accept
        // all four R beats, report error, and never issue an AW/W/B.
        $display("[TB] Inject SLVERR on second beat of mapped 4-beat read");
        for (integer j = 0; j < 4; j = j + 1) begin
            cpu_write_word(SRC_FAULT + j * 4, sample_value(j));
            cpu_write_word(DST_FAULT + j * 4, 32'hBAD0_0000 + j);
        end
        begin : injected_r_error_test
            integer ar_before, r_before, aw_before, w_before, b_before;
            integer done_before, error_before;
            ar_before = dma_ar_count;
            r_before = dma_r_count;
            aw_before = dma_aw_count;
            w_before = dma_w_count;
            b_before = dma_b_count;
            done_before = dma_done_count;
            error_before = dma_read_error_count;
            fault_rbeat_count = 0;
            fault_enable = 1'b1;
            allow_dma_read_error = 1'b1;
            cfg_launch(SRC_FAULT, DST_FAULT, 16'd4);
            do @(posedge clk); while (!dma_done);
            check(dma_error, "injected read SLVERR was reported");
            @(negedge clk);
            fault_enable = 1'b0;
            allow_dma_read_error = 1'b0;
            check(fault_rbeat_count == 4 &&
                  dma_read_error_count - error_before == 1,
                  "DMA drained every R beat after beat-1 error");
            check(dma_ar_count - ar_before == 1 &&
                  dma_r_count - r_before == 4 &&
                  dma_aw_count - aw_before == 0 &&
                  dma_w_count - w_before == 0 &&
                  dma_b_count - b_before == 0,
                  "failed read burst caused no destination write");
            check(dma_done_count - done_before == 1,
                  "read error produced one done pulse");
            cfg_read_expect(12'h010, 32'h0000_0006);
        end
        for (integer j = 0; j < 4; j = j + 1)
            cpu_read_expect(DST_FAULT + j * 4, 32'hBAD0_0000 + j, 0);

        // The first word is mapped; the next source address is outside the
        // 64 KiB data SRAM window. DMA must stop after the failing R beat.
        $display("[TB] Error on word 2: stop before second AW/W");
        cpu_write_word(SRC_EDGE, 32'h1357_9BDF);
        cpu_write_word(DST_EDGE, 32'h1111_1111);
        cpu_write_word(DST_EDGE + 32'd4, 32'h2222_2222);
        begin : middle_error_test
            integer ar_before, r_before, aw_before, w_before, b_before;
            integer done_before, error_before;
            ar_before = dma_ar_count;
            r_before = dma_r_count;
            aw_before = dma_aw_count;
            w_before = dma_w_count;
            b_before = dma_b_count;
            done_before = dma_done_count;
            error_before = dma_read_error_count;
            allow_dma_read_error = 1'b1;
            cfg_launch(SRC_EDGE, DST_EDGE, 16'd2);
            do @(posedge clk); while (!dma_done);
            check(dma_error, "mid-transfer DECERR reported to DMA caller");
            @(negedge clk);
            allow_dma_read_error = 1'b0;
            check(dma_read_error_count - error_before == 1 &&
                  decode_error_seen,
                  "one unmapped read returned DECERR");
            check(dma_ar_count - ar_before == 2 &&
                  dma_r_count - r_before == 2 &&
                  dma_aw_count - aw_before == 1 &&
                  dma_w_count - w_before == 1 &&
                  dma_b_count - b_before == 1,
                  "second-word read error prevented second write");
            check(dma_done_count - done_before == 1,
                  "mid-transfer error produced one done pulse");
            cfg_read_expect(12'h010, 32'h0000_0006);
        end
        cpu_read_expect(DST_EDGE, 32'h1357_9BDF, 0);
        cpu_read_expect(DST_EDGE + 32'd4, 32'h2222_2222, 0);

        // Reset with a multi-beat R response in progress. No write address
        // has been issued yet, and the next job must start from a clean IDLE.
        $display("[TB] Reset during an active read burst, then restart");
        cpu_write_word(SRC_RESET, 32'h89AB_CDEF);
        cpu_write_word(DST_RESET, 32'hFEED_1234);
        cfg_launch(SRC_RESET, DST_RESET, 16'd16);
        do @(posedge clk); while (!(dma_rvalid && dma_rready));
        @(negedge clk);
        reset_n = 1'b0;
        repeat (3) @(negedge clk);
        check(!dma_busy && !dma_done && !dma_error,
              "reset aborts in-flight DMA without stale status");
        cfg_read_expect(12'h010, 32'd0);
        reset_n = 1'b1;
        repeat (3) @(negedge clk);
        cpu_read_expect(DST_RESET, 32'hFEED_1234, 0);
        copy_and_check_words(SRC_RESET, DST_RESET, 1, 1'b0);

        $display("TEST PASS: DMA register-config integration, true INCR bursts, backpressure, 4KiB split, and errors; %0d checks", checks);
        $finish;
    end
endmodule
