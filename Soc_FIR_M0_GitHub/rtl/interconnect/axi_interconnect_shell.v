`timescale 1ns/1ps
`include "soc_addr_map.vh"

// One-master, one-outstanding AXI interconnect for two SRAMs, FIR and DMA MMIO.
// The previously verified SRAM decoder remains an intact child instance.
// FIR control is AXI4-Lite, so this wrapper rejects non-single-beat control
// requests instead of forwarding a burst to an interface without LEN/LAST.
module axi_interconnect_shell #(
    parameter integer UART_CLKS_PER_BIT = 434
) (
    input  wire        clk,
    input  wire        reset_n,

    input  wire [31:0] s_awaddr,
    input  wire [ 7:0] s_awlen,
    input  wire [ 2:0] s_awsize,
    input  wire [ 1:0] s_awburst,
    input  wire        s_awvalid,
    output wire        s_awready,
    input  wire [31:0] s_wdata,
    input  wire [ 3:0] s_wstrb,
    input  wire        s_wlast,
    input  wire        s_wvalid,
    output wire        s_wready,
    output wire [ 1:0] s_bresp,
    output wire        s_bvalid,
    input  wire        s_bready,

    input  wire [31:0] s_araddr,
    input  wire [ 7:0] s_arlen,
    input  wire [ 2:0] s_arsize,
    input  wire [ 1:0] s_arburst,
    input  wire        s_arvalid,
    output wire        s_arready,
    output wire [31:0] s_rdata,
    output wire [ 1:0] s_rresp,
    output wire        s_rlast,
    output wire        s_rvalid,
    input  wire        s_rready,

    // Local register interface of the DMA AXI slave. The DMA engine remains
    // outside this interconnect and will be connected in soc_fabric_shell.
    output wire        dma_cfg_wr_en,
    output wire [11:0] dma_cfg_wr_offset,
    output wire [31:0] dma_cfg_wr_data,
    output wire [11:0] dma_cfg_rd_offset,
    input  wire [31:0] dma_cfg_rd_data,

    input  wire        uart_rx,
    output wire        uart_tx,
    output wire        uart_irq,
    output wire        uart_rx_dma_req,
    output wire        uart_tx_dma_req,

    output wire        error_seen,
    output wire        fir_irq_done,
    output wire        fir_irq_ovf
);

    localparam [2:0] TARGET_SRAM      = 3'd0;
    localparam [2:0] TARGET_FIR_CTRL  = 3'd1;
    localparam [2:0] TARGET_FIR_DATA  = 3'd2;
    localparam [2:0] TARGET_LOCAL_ERR = 3'd3;
    localparam [2:0] TARGET_DMA_REG   = 3'd4;
    localparam [2:0] TARGET_UART      = 3'd5;
    localparam [1:0] AXI_OKAY         = 2'b00;
    localparam [1:0] AXI_SLVERR       = 2'b10;

    wire aw_ctrl = ((s_awaddr & `SOC_FIR_CTRL_MASK) == `SOC_FIR_CTRL_BASE);
    wire aw_data = ((s_awaddr & `SOC_FIR_DATA_MASK) == `SOC_FIR_DATA_BASE);
    wire aw_dma  = ((s_awaddr & `SOC_DMA_MASK) == `SOC_DMA_BASE);
    wire aw_uart = ((s_awaddr & `SOC_UART0_MASK) == `SOC_UART0_BASE);
    wire ar_ctrl = ((s_araddr & `SOC_FIR_CTRL_MASK) == `SOC_FIR_CTRL_BASE);
    wire ar_data = ((s_araddr & `SOC_FIR_DATA_MASK) == `SOC_FIR_DATA_BASE);
    wire ar_dma  = ((s_araddr & `SOC_DMA_MASK) == `SOC_DMA_BASE);
    wire ar_uart = ((s_araddr & `SOC_UART0_MASK) == `SOC_UART0_BASE);

    wire ctrl_aw_supported = (s_awlen == 8'd0) &&
                             (s_awsize == 3'd2) &&
                             (s_awaddr[1:0] == 2'b00) &&
                             ((s_awburst == 2'b01) || (s_awburst == 2'b00));
    wire ctrl_ar_supported = (s_arlen == 8'd0) &&
                             (s_arsize == 3'd2) &&
                             (s_araddr[1:0] == 2'b00) &&
                             ((s_arburst == 2'b01) || (s_arburst == 2'b00));

    reg        write_active;
    reg [2:0]  write_target;
    reg        read_active;
    reg [2:0]  read_target;
    reg        ctrl_bad_wlast;
    reg        local_bvalid;
    reg [7:0]  local_awlen;
    reg [7:0]  local_wbeat;
    reg        local_rvalid;
    reg [7:0]  local_arlen;
    reg [7:0]  local_rbeat;

    // This first integration allows one complete read OR write at a time.
    wire idle = !write_active && !read_active;
    wire aw_offer = reset_n && idle && s_awvalid;
    wire ar_offer = reset_n && idle && !s_awvalid && s_arvalid;

    wire ref_awvalid = aw_offer && !aw_ctrl && !aw_data && !aw_dma &&
                       !aw_uart;
    wire ctl_awvalid = aw_offer && aw_ctrl && ctrl_aw_supported;
    wire fir_awvalid = aw_offer && aw_data;
    wire dma_awvalid = aw_offer && aw_dma;
    wire uart_awvalid = aw_offer && aw_uart;
    wire ref_arvalid = ar_offer && !ar_ctrl && !ar_data && !ar_dma &&
                       !ar_uart;
    wire ctl_arvalid = ar_offer && ar_ctrl && ctrl_ar_supported;
    wire fir_arvalid = ar_offer && ar_data;
    wire dma_arvalid = ar_offer && ar_dma;
    wire uart_arvalid = ar_offer && ar_uart;

    wire ref_awready, ref_wready, ref_bvalid, ref_arready, ref_rvalid;
    wire [1:0] ref_bresp, ref_rresp;
    wire [31:0] ref_rdata;
    wire ref_rlast;
    wire ctl_awready, ctl_wready, ctl_bvalid, ctl_arready, ctl_rvalid;
    wire [1:0] ctl_bresp, ctl_rresp;
    wire [31:0] ctl_rdata;
    wire fir_awready, fir_wready, fir_bvalid, fir_arready, fir_rvalid;
    wire [1:0] fir_bresp, fir_rresp;
    wire [31:0] fir_rdata;
    wire fir_rlast;
    wire dma_awready, dma_wready, dma_bvalid, dma_arready, dma_rvalid;
    wire [1:0] dma_bresp, dma_rresp;
    wire [31:0] dma_rdata;
    wire dma_rlast;
    wire uart_awready, uart_wready, uart_bvalid, uart_arready, uart_rvalid;
    wire [1:0] uart_bresp, uart_rresp;
    wire [31:0] uart_rdata;
    wire uart_rlast;

    assign s_awready = !reset_n || !idle ? 1'b0 :
                       aw_ctrl ? (ctrl_aw_supported ? ctl_awready : 1'b1) :
                       aw_data ? fir_awready :
                       aw_dma  ? dma_awready :
                       aw_uart ? uart_awready : ref_awready;
    assign s_arready = !reset_n || !idle || s_awvalid ? 1'b0 :
                       ar_ctrl ? (ctrl_ar_supported ? ctl_arready : 1'b1) :
                       ar_data ? fir_arready :
                       ar_dma  ? dma_arready :
                       ar_uart ? uart_arready : ref_arready;
    wire aw_fire = s_awvalid && s_awready;
    wire ar_fire = s_arvalid && s_arready;

    // W has no address. Route it using the destination captured at AW.
    wire ref_wvalid = write_active && write_target == TARGET_SRAM && s_wvalid;
    wire ctl_wvalid = write_active && write_target == TARGET_FIR_CTRL && s_wvalid;
    wire fir_wvalid = write_active && write_target == TARGET_FIR_DATA && s_wvalid;
    wire dma_wvalid = write_active && write_target == TARGET_DMA_REG && s_wvalid;
    wire uart_wvalid = write_active && write_target == TARGET_UART && s_wvalid;
    assign s_wready = !reset_n || !write_active ? 1'b0 :
                      write_target == TARGET_SRAM     ? ref_wready :
                      write_target == TARGET_FIR_CTRL ? ctl_wready :
                      write_target == TARGET_FIR_DATA ? fir_wready :
                      write_target == TARGET_DMA_REG  ? dma_wready :
                      write_target == TARGET_UART     ? uart_wready :
                      write_target == TARGET_LOCAL_ERR ? !local_bvalid : 1'b0;
    wire w_fire = s_wvalid && s_wready;

    assign s_bvalid = !write_active ? 1'b0 :
                      write_target == TARGET_SRAM     ? ref_bvalid :
                      write_target == TARGET_FIR_CTRL ? ctl_bvalid :
                      write_target == TARGET_FIR_DATA ? fir_bvalid :
                      write_target == TARGET_DMA_REG  ? dma_bvalid :
                      write_target == TARGET_UART     ? uart_bvalid :
                      write_target == TARGET_LOCAL_ERR ? local_bvalid : 1'b0;
    assign s_bresp = !write_active ? AXI_OKAY :
                     write_target == TARGET_SRAM     ? ref_bresp :
                     write_target == TARGET_FIR_CTRL ?
                         (ctrl_bad_wlast ? AXI_SLVERR : ctl_bresp) :
                     write_target == TARGET_FIR_DATA ? fir_bresp :
                     write_target == TARGET_DMA_REG  ? dma_bresp :
                     write_target == TARGET_UART     ? uart_bresp : AXI_SLVERR;
    wire b_fire = s_bvalid && s_bready;

    assign s_rvalid = !read_active ? 1'b0 :
                      read_target == TARGET_SRAM      ? ref_rvalid :
                      read_target == TARGET_FIR_CTRL  ? ctl_rvalid :
                      read_target == TARGET_FIR_DATA  ? fir_rvalid :
                      read_target == TARGET_DMA_REG   ? dma_rvalid :
                      read_target == TARGET_UART      ? uart_rvalid :
                      read_target == TARGET_LOCAL_ERR ? local_rvalid : 1'b0;
    assign s_rdata = !read_active ? 32'd0 :
                     read_target == TARGET_SRAM     ? ref_rdata :
                     read_target == TARGET_FIR_CTRL ? ctl_rdata :
                     read_target == TARGET_FIR_DATA ? fir_rdata :
                     read_target == TARGET_DMA_REG  ? dma_rdata :
                     read_target == TARGET_UART     ? uart_rdata : 32'd0;
    assign s_rresp = !read_active ? AXI_OKAY :
                     read_target == TARGET_SRAM     ? ref_rresp :
                     read_target == TARGET_FIR_CTRL ? ctl_rresp :
                     read_target == TARGET_FIR_DATA ? fir_rresp :
                     read_target == TARGET_DMA_REG  ? dma_rresp :
                     read_target == TARGET_UART     ? uart_rresp : AXI_SLVERR;
    assign s_rlast = !read_active ? 1'b0 :
                     read_target == TARGET_SRAM      ? ref_rlast :
                     read_target == TARGET_FIR_CTRL  ? 1'b1 :
                     read_target == TARGET_FIR_DATA  ? fir_rlast :
                     read_target == TARGET_DMA_REG   ? dma_rlast :
                     read_target == TARGET_UART      ? uart_rlast :
                     read_target == TARGET_LOCAL_ERR ?
                         (local_rbeat == local_arlen) : 1'b0;
    wire r_fire = s_rvalid && s_rready;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            write_active   <= 1'b0;
            write_target   <= TARGET_SRAM;
            read_active    <= 1'b0;
            read_target    <= TARGET_SRAM;
            ctrl_bad_wlast <= 1'b0;
            local_bvalid   <= 1'b0;
            local_awlen    <= 8'd0;
            local_wbeat    <= 8'd0;
            local_rvalid   <= 1'b0;
            local_arlen    <= 8'd0;
            local_rbeat    <= 8'd0;
        end else begin
            if (aw_fire) begin
                write_active   <= 1'b1;
                ctrl_bad_wlast <= 1'b0;
                local_bvalid   <= 1'b0;
                local_awlen    <= s_awlen;
                local_wbeat    <= 8'd0;
                if (aw_ctrl)
                    write_target <= ctrl_aw_supported ?
                                    TARGET_FIR_CTRL : TARGET_LOCAL_ERR;
                else if (aw_data)
                    write_target <= TARGET_FIR_DATA;
                else if (aw_dma)
                    write_target <= TARGET_DMA_REG;
                else if (aw_uart)
                    write_target <= TARGET_UART;
                else
                    write_target <= TARGET_SRAM;
            end
            if (w_fire && write_target == TARGET_FIR_CTRL && !s_wlast)
                ctrl_bad_wlast <= 1'b1;
            if (w_fire && write_target == TARGET_LOCAL_ERR) begin
                if (local_wbeat == local_awlen)
                    local_bvalid <= 1'b1;
                else
                    local_wbeat <= local_wbeat + 8'd1;
            end
            if (b_fire) begin
                write_active <= 1'b0;
                local_bvalid <= 1'b0;
            end

            if (ar_fire) begin
                read_active  <= 1'b1;
                local_arlen  <= s_arlen;
                local_rbeat  <= 8'd0;
                local_rvalid <= 1'b0;
                if (ar_ctrl) begin
                    if (ctrl_ar_supported)
                        read_target <= TARGET_FIR_CTRL;
                    else begin
                        read_target  <= TARGET_LOCAL_ERR;
                        local_rvalid <= 1'b1;
                    end
                end else if (ar_data)
                    read_target <= TARGET_FIR_DATA;
                else if (ar_dma)
                    read_target <= TARGET_DMA_REG;
                else if (ar_uart)
                    read_target <= TARGET_UART;
                else
                    read_target <= TARGET_SRAM;
            end
            if (r_fire) begin
                if (s_rlast) begin
                    read_active  <= 1'b0;
                    local_rvalid <= 1'b0;
                end else if (read_target == TARGET_LOCAL_ERR)
                    local_rbeat <= local_rbeat + 8'd1;
            end
        end
    end

    // The original SRAM fabric handles both mapped SRAMs and DECERR for all
    // other non-FIR/non-DMA addresses. Keep its instance name for CPU tests.
    axi_interconnect_shell_reference u_two_sram (
        .clk(clk), .reset_n(reset_n),
        .s_awaddr(s_awaddr), .s_awlen(s_awlen),
        .s_awsize(s_awsize), .s_awburst(s_awburst),
        .s_awvalid(ref_awvalid), .s_awready(ref_awready),
        .s_wdata(s_wdata), .s_wstrb(s_wstrb), .s_wlast(s_wlast),
        .s_wvalid(ref_wvalid), .s_wready(ref_wready),
        .s_bresp(ref_bresp), .s_bvalid(ref_bvalid),
        .s_bready(write_active && write_target == TARGET_SRAM && s_bready),
        .s_araddr(s_araddr), .s_arlen(s_arlen),
        .s_arsize(s_arsize), .s_arburst(s_arburst),
        .s_arvalid(ref_arvalid), .s_arready(ref_arready),
        .s_rdata(ref_rdata), .s_rresp(ref_rresp),
        .s_rlast(ref_rlast), .s_rvalid(ref_rvalid),
        .s_rready(read_active && read_target == TARGET_SRAM && s_rready),
        .error_seen(error_seen)
    );

    fir_subsystem u_fir (
        .aclk(clk), .aresetn(reset_n),
        .ctrl_awaddr(s_awaddr[11:0]),
        .ctrl_awvalid(ctl_awvalid), .ctrl_awready(ctl_awready),
        .ctrl_wdata(s_wdata), .ctrl_wstrb(s_wstrb),
        .ctrl_wvalid(ctl_wvalid), .ctrl_wready(ctl_wready),
        .ctrl_bresp(ctl_bresp), .ctrl_bvalid(ctl_bvalid),
        .ctrl_bready(write_active && write_target == TARGET_FIR_CTRL && s_bready),
        .ctrl_araddr(s_araddr[11:0]),
        .ctrl_arvalid(ctl_arvalid), .ctrl_arready(ctl_arready),
        .ctrl_rdata(ctl_rdata), .ctrl_rresp(ctl_rresp),
        .ctrl_rvalid(ctl_rvalid),
        .ctrl_rready(read_active && read_target == TARGET_FIR_CTRL && s_rready),
        .data_awaddr(s_awaddr), .data_awlen(s_awlen),
        .data_awsize(s_awsize), .data_awburst(s_awburst),
        .data_awvalid(fir_awvalid), .data_awready(fir_awready),
        .data_wdata(s_wdata), .data_wstrb(s_wstrb), .data_wlast(s_wlast),
        .data_wvalid(fir_wvalid), .data_wready(fir_wready),
        .data_bresp(fir_bresp), .data_bvalid(fir_bvalid),
        .data_bready(write_active && write_target == TARGET_FIR_DATA && s_bready),
        .data_araddr(s_araddr), .data_arlen(s_arlen),
        .data_arsize(s_arsize), .data_arburst(s_arburst),
        .data_arvalid(fir_arvalid), .data_arready(fir_arready),
        .data_rdata(fir_rdata), .data_rresp(fir_rresp),
        .data_rlast(fir_rlast), .data_rvalid(fir_rvalid),
        .data_rready(read_active && read_target == TARGET_FIR_DATA && s_rready),
        .irq_done(fir_irq_done), .irq_ovf(fir_irq_ovf)
    );

    // Only register access lives here. The DMA AXI master is instantiated
    // outside this decoder and enters through the upstream arbiter.
    axi_dma_reg_slave u_dma_mmio (
        .clk(clk), .reset_n(reset_n),
        .s_awaddr(s_awaddr), .s_awlen(s_awlen),
        .s_awsize(s_awsize), .s_awburst(s_awburst),
        .s_awvalid(dma_awvalid), .s_awready(dma_awready),
        .s_wdata(s_wdata), .s_wstrb(s_wstrb), .s_wlast(s_wlast),
        .s_wvalid(dma_wvalid), .s_wready(dma_wready),
        .s_bresp(dma_bresp), .s_bvalid(dma_bvalid),
        .s_bready(write_active && write_target == TARGET_DMA_REG && s_bready),
        .s_araddr(s_araddr), .s_arlen(s_arlen),
        .s_arsize(s_arsize), .s_arburst(s_arburst),
        .s_arvalid(dma_arvalid), .s_arready(dma_arready),
        .s_rdata(dma_rdata), .s_rresp(dma_rresp),
        .s_rlast(dma_rlast), .s_rvalid(dma_rvalid),
        .s_rready(read_active && read_target == TARGET_DMA_REG && s_rready),
        .cfg_wr_en(dma_cfg_wr_en),
        .cfg_wr_offset(dma_cfg_wr_offset),
        .cfg_wr_data(dma_cfg_wr_data),
        .cfg_rd_offset(dma_cfg_rd_offset),
        .cfg_rd_data(dma_cfg_rd_data)
    );

    axi_apb_uart_subsystem #(
        .CLKS_PER_BIT(UART_CLKS_PER_BIT)
    ) u_uart_subsystem (
        .clk(clk), .reset_n(reset_n),
        .s_awaddr(s_awaddr), .s_awlen(s_awlen),
        .s_awsize(s_awsize), .s_awburst(s_awburst),
        .s_awvalid(uart_awvalid), .s_awready(uart_awready),
        .s_wdata(s_wdata), .s_wstrb(s_wstrb), .s_wlast(s_wlast),
        .s_wvalid(uart_wvalid), .s_wready(uart_wready),
        .s_bresp(uart_bresp), .s_bvalid(uart_bvalid),
        .s_bready(write_active && write_target == TARGET_UART && s_bready),
        .s_araddr(s_araddr), .s_arlen(s_arlen),
        .s_arsize(s_arsize), .s_arburst(s_arburst),
        .s_arvalid(uart_arvalid), .s_arready(uart_arready),
        .s_rdata(uart_rdata), .s_rresp(uart_rresp),
        .s_rlast(uart_rlast), .s_rvalid(uart_rvalid),
        .s_rready(read_active && read_target == TARGET_UART && s_rready),
        .uart_rx(uart_rx), .uart_tx(uart_tx), .uart_irq(uart_irq),
        .uart_rx_dma_req(uart_rx_dma_req),
        .uart_tx_dma_req(uart_tx_dma_req)
    );

endmodule
