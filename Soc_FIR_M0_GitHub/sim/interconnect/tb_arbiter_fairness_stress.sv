`timescale 1ns/1ps

// 两个 AXI 主机持续同时请求的公平性压力测试。
// CPU 与 DMA 始终保持 ARVALID；下游每次返回一个单拍读响应。
// 公平仲裁器应让两者交替前进，而不是让 DMA 永久得不到 ARREADY。
module tb_arbiter_fairness_stress;
    reg clk = 1'b0;
    reg reset_n = 1'b0;

    reg        cpu_arvalid = 1'b0;
    reg [31:0] cpu_araddr  = 32'h2000_0000;
    wire       cpu_arready;
    wire [31:0] cpu_rdata;
    wire [1:0]  cpu_rresp;
    wire        cpu_rlast;
    wire        cpu_rvalid;

    reg        dma_arvalid = 1'b0;
    reg [31:0] dma_araddr  = 32'h2000_1000;
    wire       dma_arready;
    wire [31:0] dma_rdata;
    wire [1:0]  dma_rresp;
    wire        dma_rlast;
    wire        dma_rvalid;

    wire [31:0] m_araddr;
    wire [7:0]  m_arlen;
    wire [2:0]  m_arsize;
    wire [1:0]  m_arburst;
    wire        m_arvalid;
    reg         m_arready = 1'b1;
    reg  [31:0] m_rdata = 32'd0;
    reg  [1:0]  m_rresp = 2'b00;
    reg         m_rlast = 1'b0;
    reg         m_rvalid = 1'b0;
    wire        m_rready;

    integer cpu_grants = 0;
    integer dma_grants = 0;
    integer total_grants = 0;
    integer wait_cycles = 0;
    integer max_dma_wait = 0;
    reg last_grant_valid = 1'b0;
    reg last_grant_dma = 1'b0;

    always #5 clk = ~clk;

    arbiter dut (
        .clk(clk),
        .reset_n(reset_n),

        .cpu_araddr(cpu_araddr),
        .cpu_arlen(8'd0),
        .cpu_arsize(3'b010),
        .cpu_arburst(2'b01),
        .cpu_arvalid(cpu_arvalid),
        .cpu_arready(cpu_arready),
        .cpu_rdata(cpu_rdata),
        .cpu_rresp(cpu_rresp),
        .cpu_rlast(cpu_rlast),
        .cpu_rvalid(cpu_rvalid),
        .cpu_rready(1'b1),

        .cpu_awaddr(32'd0), .cpu_awlen(8'd0),
        .cpu_awsize(3'b010), .cpu_awburst(2'b01),
        .cpu_awvalid(1'b0), .cpu_awready(),
        .cpu_wdata(32'd0), .cpu_wstrb(4'd0),
        .cpu_wlast(1'b0), .cpu_wvalid(1'b0), .cpu_wready(),
        .cpu_bresp(), .cpu_bvalid(), .cpu_bready(1'b1),

        .dma_araddr(dma_araddr),
        .dma_arlen(8'd0),
        .dma_arsize(3'b010),
        .dma_arburst(2'b01),
        .dma_arvalid(dma_arvalid),
        .dma_arready(dma_arready),
        .dma_rdata(dma_rdata),
        .dma_rresp(dma_rresp),
        .dma_rlast(dma_rlast),
        .dma_rvalid(dma_rvalid),
        .dma_rready(1'b1),

        .dma_awaddr(32'd0), .dma_awlen(8'd0),
        .dma_awsize(3'b010), .dma_awburst(2'b01),
        .dma_awvalid(1'b0), .dma_awready(),
        .dma_wdata(32'd0), .dma_wstrb(4'd0),
        .dma_wlast(1'b0), .dma_wvalid(1'b0), .dma_wready(),
        .dma_bresp(), .dma_bvalid(), .dma_bready(1'b1),

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

        .m_awaddr(), .m_awlen(), .m_awsize(), .m_awburst(),
        .m_awvalid(), .m_awready(1'b1),
        .m_wdata(), .m_wstrb(), .m_wlast(), .m_wvalid(),
        .m_wready(1'b1),
        .m_bresp(2'b00), .m_bvalid(1'b0), .m_bready()
    );

    // 最小下游 AXI 读从机：接受 AR 后，在下一周期给出单拍 R。
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            m_rvalid <= 1'b0;
            m_rlast  <= 1'b0;
            m_rdata  <= 32'd0;
            m_rresp  <= 2'b00;
        end else begin
            if (m_rvalid && m_rready) begin
                m_rvalid <= 1'b0;
                m_rlast  <= 1'b0;
            end
            if (m_arvalid && m_arready) begin
                m_rvalid <= 1'b1;
                m_rlast  <= 1'b1;
                m_rdata  <= m_araddr ^ 32'h55AA_0000;
                m_rresp  <= 2'b00;
            end
        end
    end

    // 两个主机在一次请求被接收后，立刻准备下一次请求。
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            cpu_araddr <= 32'h2000_0000;
            dma_araddr <= 32'h2000_1000;
            cpu_grants <= 0;
            dma_grants <= 0;
            total_grants <= 0;
            wait_cycles <= 0;
            max_dma_wait <= 0;
            last_grant_valid <= 1'b0;
            last_grant_dma <= 1'b0;
        end else begin
            if (cpu_arvalid && cpu_arready) begin
                if (last_grant_valid && !last_grant_dma)
                    $fatal(1, "TEST FAIL: CPU连续获准，DMA发生不公平等待");
                cpu_araddr <= cpu_araddr + 32'd4;
                cpu_grants <= cpu_grants + 1;
                total_grants <= total_grants + 1;
                last_grant_valid <= 1'b1;
                last_grant_dma <= 1'b0;
            end

            if (dma_arvalid && dma_arready) begin
                if (last_grant_valid && last_grant_dma)
                    $fatal(1, "TEST FAIL: DMA连续获准，CPU发生不公平等待");
                dma_araddr <= dma_araddr + 32'd4;
                dma_grants <= dma_grants + 1;
                total_grants <= total_grants + 1;
                last_grant_valid <= 1'b1;
                last_grant_dma <= 1'b1;
                if (wait_cycles > max_dma_wait)
                    max_dma_wait <= wait_cycles;
                wait_cycles <= 0;
            end else if (dma_arvalid) begin
                wait_cycles <= wait_cycles + 1;
                if (wait_cycles >= 12)
                    $fatal(1, "TEST FAIL: DMA持续请求超过12周期仍未获准");
            end
        end
    end

    initial begin
        $display("Starting CPU/DMA continuous-contention fairness stress test");
        repeat (5) @(posedge clk);
        @(negedge clk);
        reset_n = 1'b1;
        cpu_arvalid = 1'b1;
        dma_arvalid = 1'b1;

        repeat (250) begin
            @(posedge clk);
            if (cpu_grants >= 20 && dma_grants >= 20) begin
                $display("TEST PASS: cpu_grants=%0d dma_grants=%0d max_dma_wait=%0d",
                         cpu_grants, dma_grants, max_dma_wait);
                $finish;
            end
        end

        $fatal(1, "TEST FAIL: timeout cpu_grants=%0d dma_grants=%0d",
               cpu_grants, dma_grants);
    end
endmodule
