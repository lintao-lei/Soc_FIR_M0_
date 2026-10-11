`timescale 1ns/1ps

// CPU与DMA持续同时发起单拍写事务。
// 顶层仲裁器应在两者之间轮询，并将AW/W/B整笔事务锁定给同一主机。
module tb_arbiter_write_fairness_stress;
    reg clk = 1'b0;
    reg reset_n = 1'b0;

    reg         cpu_awvalid = 1'b0;
    reg [31:0]  cpu_awaddr  = 32'h2000_0000;
    wire        cpu_awready;
    reg         cpu_wvalid  = 1'b0;
    wire        cpu_wready;
    wire        cpu_bvalid;
    wire [1:0]  cpu_bresp;

    reg         dma_awvalid = 1'b0;
    reg [31:0]  dma_awaddr  = 32'h2000_1000;
    wire        dma_awready;
    reg         dma_wvalid  = 1'b0;
    wire        dma_wready;
    wire        dma_bvalid;
    wire [1:0]  dma_bresp;

    wire [31:0] m_awaddr;
    wire [7:0]  m_awlen;
    wire [2:0]  m_awsize;
    wire [1:0]  m_awburst;
    wire        m_awvalid;
    reg         m_awready = 1'b1;
    wire [31:0] m_wdata;
    wire [3:0]  m_wstrb;
    wire        m_wlast;
    wire        m_wvalid;
    reg         m_wready = 1'b1;
    reg  [1:0]  m_bresp = 2'b00;
    reg         m_bvalid = 1'b0;
    wire        m_bready;

    reg seen_aw = 1'b0;
    reg seen_w = 1'b0;
    integer cpu_grants = 0;
    integer dma_grants = 0;
    integer cpu_responses = 0;
    integer dma_responses = 0;
    integer dma_wait_cycles = 0;
    integer max_dma_wait = 0;
    reg last_grant_valid = 1'b0;
    reg last_grant_dma = 1'b0;

    wire m_aw_fire = m_awvalid && m_awready;
    wire m_w_fire = m_wvalid && m_wready && m_wlast;

    always #5 clk = ~clk;

    arbiter dut (
        .clk(clk),
        .reset_n(reset_n),

        .cpu_araddr(32'd0), .cpu_arlen(8'd0),
        .cpu_arsize(3'b010), .cpu_arburst(2'b01),
        .cpu_arvalid(1'b0), .cpu_arready(),
        .cpu_rdata(), .cpu_rresp(), .cpu_rlast(), .cpu_rvalid(),
        .cpu_rready(1'b1),

        .cpu_awaddr(cpu_awaddr), .cpu_awlen(8'd0),
        .cpu_awsize(3'b010), .cpu_awburst(2'b01),
        .cpu_awvalid(cpu_awvalid), .cpu_awready(cpu_awready),
        .cpu_wdata(cpu_awaddr ^ 32'h1111_0000),
        .cpu_wstrb(4'b1111), .cpu_wlast(1'b1),
        .cpu_wvalid(cpu_wvalid), .cpu_wready(cpu_wready),
        .cpu_bresp(cpu_bresp), .cpu_bvalid(cpu_bvalid),
        .cpu_bready(1'b1),

        .dma_araddr(32'd0), .dma_arlen(8'd0),
        .dma_arsize(3'b010), .dma_arburst(2'b01),
        .dma_arvalid(1'b0), .dma_arready(),
        .dma_rdata(), .dma_rresp(), .dma_rlast(), .dma_rvalid(),
        .dma_rready(1'b1),

        .dma_awaddr(dma_awaddr), .dma_awlen(8'd0),
        .dma_awsize(3'b010), .dma_awburst(2'b01),
        .dma_awvalid(dma_awvalid), .dma_awready(dma_awready),
        .dma_wdata(dma_awaddr ^ 32'h2222_0000),
        .dma_wstrb(4'b1111), .dma_wlast(1'b1),
        .dma_wvalid(dma_wvalid), .dma_wready(dma_wready),
        .dma_bresp(dma_bresp), .dma_bvalid(dma_bvalid),
        .dma_bready(1'b1),

        .m_araddr(), .m_arlen(), .m_arsize(), .m_arburst(),
        .m_arvalid(), .m_arready(1'b1),
        .m_rdata(32'd0), .m_rresp(2'b00),
        .m_rlast(1'b0), .m_rvalid(1'b0), .m_rready(),

        .m_awaddr(m_awaddr), .m_awlen(m_awlen),
        .m_awsize(m_awsize), .m_awburst(m_awburst),
        .m_awvalid(m_awvalid), .m_awready(m_awready),
        .m_wdata(m_wdata), .m_wstrb(m_wstrb),
        .m_wlast(m_wlast), .m_wvalid(m_wvalid),
        .m_wready(m_wready),
        .m_bresp(m_bresp), .m_bvalid(m_bvalid), .m_bready(m_bready)
    );

    // 最小AXI写从机：收齐AW和最后一拍W后返回一个OKAY响应。
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            seen_aw  <= 1'b0;
            seen_w   <= 1'b0;
            m_bvalid <= 1'b0;
            m_bresp  <= 2'b00;
        end else begin
            if (m_bvalid && m_bready)
                m_bvalid <= 1'b0;

            if (!m_bvalid &&
                (seen_aw || m_aw_fire) &&
                (seen_w  || m_w_fire)) begin
                seen_aw  <= 1'b0;
                seen_w   <= 1'b0;
                m_bvalid <= 1'b1;
                m_bresp  <= 2'b00;
            end else begin
                if (m_aw_fire)
                    seen_aw <= 1'b1;
                if (m_w_fire)
                    seen_w <= 1'b1;
            end
        end
    end

    // 统计双方获得的地址授权和收到的B响应。
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            cpu_awaddr <= 32'h2000_0000;
            dma_awaddr <= 32'h2000_1000;
            cpu_grants <= 0;
            dma_grants <= 0;
            cpu_responses <= 0;
            dma_responses <= 0;
            dma_wait_cycles <= 0;
            max_dma_wait <= 0;
            last_grant_valid <= 1'b0;
            last_grant_dma <= 1'b0;
        end else begin
            if (cpu_awvalid && cpu_awready) begin
                if (last_grant_valid && !last_grant_dma)
                    $fatal(1, "TEST FAIL: CPU连续获得写授权，DMA未轮到");
                cpu_awaddr <= cpu_awaddr + 32'd4;
                cpu_grants <= cpu_grants + 1;
                last_grant_valid <= 1'b1;
                last_grant_dma <= 1'b0;
            end

            if (dma_awvalid && dma_awready) begin
                if (last_grant_valid && last_grant_dma)
                    $fatal(1, "TEST FAIL: DMA连续获得写授权，CPU未轮到");
                dma_awaddr <= dma_awaddr + 32'd4;
                dma_grants <= dma_grants + 1;
                last_grant_valid <= 1'b1;
                last_grant_dma <= 1'b1;
                if (dma_wait_cycles > max_dma_wait)
                    max_dma_wait <= dma_wait_cycles;
                dma_wait_cycles <= 0;
            end else if (dma_awvalid) begin
                dma_wait_cycles <= dma_wait_cycles + 1;
                if (dma_wait_cycles >= 16)
                    $fatal(1, "TEST FAIL: DMA写请求持续超过16周期仍未获准");
            end

            if (cpu_bvalid) begin
                if (cpu_bresp != 2'b00)
                    $fatal(1, "TEST FAIL: CPU收到错误BRESP");
                cpu_responses <= cpu_responses + 1;
            end
            if (dma_bvalid) begin
                if (dma_bresp != 2'b00)
                    $fatal(1, "TEST FAIL: DMA收到错误BRESP");
                dma_responses <= dma_responses + 1;
            end
        end
    end

    initial begin
        $display("Starting CPU/DMA continuous write-contention stress test");
        repeat (5) @(posedge clk);
        @(negedge clk);
        reset_n = 1'b1;
        cpu_awvalid = 1'b1;
        cpu_wvalid  = 1'b1;
        dma_awvalid = 1'b1;
        dma_wvalid  = 1'b1;

        repeat (500) begin
            @(posedge clk);
            if (cpu_responses >= 20 && dma_responses >= 20) begin
                $display("TEST PASS: cpu_grants=%0d dma_grants=%0d cpu_B=%0d dma_B=%0d max_dma_wait=%0d",
                         cpu_grants, dma_grants,
                         cpu_responses, dma_responses, max_dma_wait);
                $finish;
            end
        end

        $fatal(1, "TEST FAIL: timeout cpu_grants=%0d dma_grants=%0d cpu_B=%0d dma_B=%0d",
               cpu_grants, dma_grants, cpu_responses, dma_responses);
    end
endmodule
