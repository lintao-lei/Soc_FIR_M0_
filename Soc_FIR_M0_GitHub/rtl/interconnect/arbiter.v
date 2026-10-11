`timescale 1ns/1ps

// One two-master AXI shell. Read and write arbitrate independently.
// Global admission allows one unfinished AXI transaction across read and write.
module arbiter (
    input  wire         clk,
    input  wire         reset_n,
    input  wire [31:0]  cpu_araddr,
    input  wire [7:0]   cpu_arlen,
    input  wire [2:0]   cpu_arsize,
    input  wire [1:0]   cpu_arburst,
    input  wire         cpu_arvalid,
    output wire         cpu_arready,
    output wire [31:0]  cpu_rdata,
    output wire [1:0]   cpu_rresp,
    output wire         cpu_rlast,
    output wire         cpu_rvalid,
    input  wire         cpu_rready,
    input  wire [31:0]  cpu_awaddr,
    input  wire [7:0]   cpu_awlen,
    input  wire [2:0]   cpu_awsize,
    input  wire [1:0]   cpu_awburst,
    input  wire         cpu_awvalid,
    output wire         cpu_awready,
    input  wire [31:0]  cpu_wdata,
    input  wire [3:0]   cpu_wstrb,
    input  wire         cpu_wlast,
    input  wire         cpu_wvalid,
    output wire         cpu_wready,
    output wire [1:0]   cpu_bresp,
    output wire         cpu_bvalid,
    input  wire         cpu_bready,
    input  wire [31:0]  dma_araddr,
    input  wire [7:0]   dma_arlen,
    input  wire [2:0]   dma_arsize,
    input  wire [1:0]   dma_arburst,
    input  wire         dma_arvalid,
    output wire         dma_arready,
    output wire [31:0]  dma_rdata,
    output wire [1:0]   dma_rresp,
    output wire         dma_rlast,
    output wire         dma_rvalid,
    input  wire         dma_rready,
    input  wire [31:0]  dma_awaddr,
    input  wire [7:0]   dma_awlen,
    input  wire [2:0]   dma_awsize,
    input  wire [1:0]   dma_awburst,
    input  wire         dma_awvalid,
    output wire         dma_awready,
    input  wire [31:0]  dma_wdata,
    input  wire [3:0]   dma_wstrb,
    input  wire         dma_wlast,
    input  wire         dma_wvalid,
    output wire         dma_wready,
    output wire [1:0]   dma_bresp,
    output wire         dma_bvalid,
    input  wire         dma_bready,
    output wire [31:0]  m_araddr,
    output wire [7:0]   m_arlen,
    output wire [2:0]   m_arsize,
    output wire [1:0]   m_arburst,
    output wire         m_arvalid,
    input  wire         m_arready,
    input  wire [31:0]  m_rdata,
    input  wire [1:0]   m_rresp,
    input  wire         m_rlast,
    input  wire         m_rvalid,
    output wire         m_rready,
    output wire [31:0]  m_awaddr,
    output wire [7:0]   m_awlen,
    output wire [2:0]   m_awsize,
    output wire [1:0]   m_awburst,
    output wire         m_awvalid,
    input  wire         m_awready,
    output wire [31:0]  m_wdata,
    output wire [3:0]   m_wstrb,
    output wire         m_wlast,
    output wire         m_wvalid,
    input  wire         m_wready,
    input  wire [1:0]   m_bresp,
    input  wire         m_bvalid,
    output wire         m_bready
);

    // 任意时刻只允许一笔读或写事务占用下游。
    // CPU 和 DMA 之间采用主机级轮询：若双方同时请求，优先选择上一次
    // 没有获准的主机；同一主机内部仍保持“读地址优先于写地址”。
    // 一旦地址握手，归属保持到读 RLAST 握手或写 B 握手，Burst 中途
    // 绝不会切换给另一主机。
    reg transaction_active;
    reg transaction_is_write;
    reg last_owner_dma;

    wire cpu_request = cpu_arvalid || cpu_awvalid;
    wire dma_request = dma_arvalid || dma_awvalid;

    // last_owner_dma=1 表示上一笔属于 DMA；双方冲突时下一笔选 CPU。
    // last_owner_dma=0 时则相反。复位把它置 1，使首次冲突仍由 CPU 先行。
    wire choose_cpu = reset_n && !transaction_active && cpu_request &&
                      (!dma_request || last_owner_dma);
    wire choose_dma = reset_n && !transaction_active && dma_request &&
                      (!cpu_request || !last_owner_dma);

    wire grant_cpu_ar = choose_cpu && cpu_arvalid;
    wire grant_cpu_aw = choose_cpu && !cpu_arvalid && cpu_awvalid;
    wire grant_dma_ar = choose_dma && dma_arvalid;
    wire grant_dma_aw = choose_dma && !dma_arvalid && dma_awvalid;

    wire read_cpu_arready;
    wire read_dma_arready;
    wire write_cpu_awready;
    wire write_dma_awready;
    assign cpu_arready = grant_cpu_ar && read_cpu_arready;
    assign cpu_awready = grant_cpu_aw && write_cpu_awready;
    assign dma_arready = grant_dma_ar && read_dma_arready;
    assign dma_awready = grant_dma_aw && write_dma_awready;

    wire read_address_fire = (cpu_arvalid && cpu_arready) ||
                             (dma_arvalid && dma_arready);
    wire write_address_fire = (cpu_awvalid && cpu_awready) ||
                              (dma_awvalid && dma_awready);
    wire read_last_fire = (cpu_rvalid && cpu_rready && cpu_rlast) ||
                          (dma_rvalid && dma_rready && dma_rlast);
    wire write_response_fire = (cpu_bvalid && cpu_bready) ||
                               (dma_bvalid && dma_bready);

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            transaction_active   <= 1'b0;
            transaction_is_write <= 1'b0;
            last_owner_dma       <= 1'b1;
        end else if (!transaction_active) begin
            if (read_address_fire) begin
                transaction_active   <= 1'b1;
                transaction_is_write <= 1'b0;
                last_owner_dma       <= dma_arvalid && dma_arready;
            end else if (write_address_fire) begin
                transaction_active   <= 1'b1;
                transaction_is_write <= 1'b1;
                last_owner_dma       <= dma_awvalid && dma_awready;
            end
        end else if (transaction_is_write ? write_response_fire
                                          : read_last_fire) begin
            transaction_active <= 1'b0;
        end
    end

    read_arbiter u_read_arbiter (
        .clk(clk),
        .reset_n(reset_n),
        .cpu_araddr(cpu_araddr),
        .cpu_arlen(cpu_arlen),
        .cpu_arsize(cpu_arsize),
        .cpu_arburst(cpu_arburst),
        .cpu_arvalid(grant_cpu_ar),
        .cpu_arready(read_cpu_arready),
        .cpu_rdata(cpu_rdata),
        .cpu_rresp(cpu_rresp),
        .cpu_rlast(cpu_rlast),
        .cpu_rvalid(cpu_rvalid),
        .cpu_rready(cpu_rready),
        .dma_araddr(dma_araddr),
        .dma_arlen(dma_arlen),
        .dma_arsize(dma_arsize),
        .dma_arburst(dma_arburst),
        .dma_arvalid(grant_dma_ar),
        .dma_arready(read_dma_arready),
        .dma_rdata(dma_rdata),
        .dma_rresp(dma_rresp),
        .dma_rlast(dma_rlast),
        .dma_rvalid(dma_rvalid),
        .dma_rready(dma_rready),
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
        .m_rready(m_rready)
    );

    write_arbiter u_write_arbiter (
        .clk(clk),
        .reset_n(reset_n),
        .cpu_awaddr(cpu_awaddr),
        .cpu_awlen(cpu_awlen),
        .cpu_awsize(cpu_awsize),
        .cpu_awburst(cpu_awburst),
        .cpu_awvalid(grant_cpu_aw),
        .cpu_awready(write_cpu_awready),
        .cpu_wdata(cpu_wdata),
        .cpu_wstrb(cpu_wstrb),
        .cpu_wlast(cpu_wlast),
        .cpu_wvalid(cpu_wvalid),
        .cpu_wready(cpu_wready),
        .cpu_bresp(cpu_bresp),
        .cpu_bvalid(cpu_bvalid),
        .cpu_bready(cpu_bready),
        .dma_awaddr(dma_awaddr),
        .dma_awlen(dma_awlen),
        .dma_awsize(dma_awsize),
        .dma_awburst(dma_awburst),
        .dma_awvalid(grant_dma_aw),
        .dma_awready(write_dma_awready),
        .dma_wdata(dma_wdata),
        .dma_wstrb(dma_wstrb),
        .dma_wlast(dma_wlast),
        .dma_wvalid(dma_wvalid),
        .dma_wready(dma_wready),
        .dma_bresp(dma_bresp),
        .dma_bvalid(dma_bvalid),
        .dma_bready(dma_bready),
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
endmodule
