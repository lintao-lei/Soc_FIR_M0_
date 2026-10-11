`timescale 1ns/1ps

// ============================================================================
// FIR 控制封装：AXI4-Lite 寄存器接口 + AXI-Stream 样本接口
// ----------------------------------------------------------------------------
// 软件通过 AXI4-Lite 配置使能、系数、帧长度和中断；大批量样本通过
// AXI-Stream 输入/输出。也可以向 DATA_IN 写一个样本，便于软件单步调试。
//
// 系数采用双缓冲：
//   shadow_coeff[]：软件可读写的影子系数，不会立即影响正在工作的滤波器；
//   work_coeff[]  ：FIR 核心实际使用的活动系数；
//   写 CTRL.LOAD 后，整组影子系数在同一时钟沿复制到活动系数，避免半更新。
//
// 寄存器表（均要求 32 位对齐）：
//   0x000 CTRL     bit0=EN，bit1=LOAD（脉冲），bit2=CLR（脉冲）
//   0x004 STATUS   bit0=BUSY，bit1=DONE，bit2=OVERFLOW；写 1 清 sticky 位
//   0x008 DATA_IN  写入低 16 位作为一个 Q15 输入样本
//   0x00C DATA_OUT 最近一次被下游接收的 32 位输出
//   0x010~0x150    81 个 Q15 系数，每个系数占一个 32 位地址
//   0x158 LEN      一帧期望产生的输出样本数，达到后置位 DONE
//   0x15C IRQ_EN   bit0=完成中断使能，bit1=溢出中断使能
// ============================================================================
module fir_81tap_axi #(
    parameter integer N_TAP = 81
)(
    // AXI4-Lite 时钟与低有效异步复位
    input  wire        aclk,
    input  wire        aresetn,

    // AXI4-Lite 写地址、写数据和写响应通道
    input  wire [11:0] s_axil_awaddr,
    input  wire        s_axil_awvalid,
    output wire        s_axil_awready,
    input  wire [31:0] s_axil_wdata,
    input  wire [3:0]  s_axil_wstrb,
    input  wire        s_axil_wvalid,
    output wire        s_axil_wready,
    output reg  [1:0]  s_axil_bresp,
    output reg         s_axil_bvalid,
    input  wire        s_axil_bready,

    // AXI4-Lite 读地址和读数据通道
    input  wire [11:0] s_axil_araddr,
    input  wire        s_axil_arvalid,
    output wire        s_axil_arready,
    output reg  [31:0] s_axil_rdata,
    output reg  [1:0]  s_axil_rresp,
    output reg         s_axil_rvalid,
    input  wire        s_axil_rready,

    // 连续样本流：输入为 Q15，输出为量化后的有符号 32 位结果
    input  wire signed [15:0] s_axis_tdata,
    input  wire               s_axis_tvalid,
    output wire               s_axis_tready,
    output wire signed [31:0] m_axis_tdata,
    output wire               m_axis_tvalid,
    input  wire               m_axis_tready,

    // Data-window coordination: a clear is accepted only between AXI data
    // transactions, so a stalled R response never changes under the master.
    input  wire               data_busy,
    output wire               data_enabled,
    output wire               data_clear_request,
    output wire               data_clear,

    // 电平中断：sticky 状态置位且相应 IRQ_EN 位打开时保持为 1
    output wire irq_done,
    output wire irq_ovf
);
    // --------------------------- CSR 地址映射 ---------------------------
    localparam [11:0] ADDR_CTRL     = 12'h000;
    localparam [11:0] ADDR_STATUS   = 12'h004;
    localparam [11:0] ADDR_DATA_IN  = 12'h008;
    localparam [11:0] ADDR_DATA_OUT = 12'h00C;
    localparam [11:0] ADDR_COEFF0   = 12'h010;
    localparam [11:0] ADDR_COEFFN   = 12'h150;
    localparam [11:0] ADDR_LEN      = 12'h158;
    localparam [11:0] ADDR_IRQ_EN   = 12'h15C;

    // ------------------------ 控制、状态与计数器 -------------------------
    reg        enable_reg;
    // bit0 允许 DONE 中断；bit1 允许溢出中断。
    reg [1:0]  irq_enable_reg;
    reg [15:0] length_reg;
    reg [15:0] output_count;
    reg        done_sticky;
    reg        ovf_sticky;
    reg [31:0] last_output;

    // 影子系数供软件更新，活动系数供 FIR 使用；二者分离保证原子切换。
    reg signed [15:0] shadow_coeff [0:N_TAP-1];
    reg signed [15:0] work_coeff   [0:N_TAP-1];
    wire [N_TAP*16-1:0] work_coeff_flat;

    // FIR 核心使用一条扁平总线，因此把活动系数数组重新拼接成宽向量。
    genvar coeff_index;
    generate
        for (coeff_index = 0; coeff_index < N_TAP; coeff_index = coeff_index + 1) begin : g_coeff_flat
            assign work_coeff_flat[coeff_index*16 +: 16] = work_coeff[coeff_index];
        end
    endgenerate

    // AXI-Lite 允许 AW（地址）和 W（数据）通道独立到达。
    // 暂存寄存器用于等待两者都到齐，write_commit 才真正执行一次 CSR 写入。
    reg [11:0] awaddr_hold;
    reg        aw_hold_valid;
    reg [31:0] wdata_hold;
    reg [3:0]  wstrb_hold;
    reg        w_hold_valid;

    assign s_axil_awready = !aw_hold_valid && !s_axil_bvalid;
    assign s_axil_wready  = !w_hold_valid  && !s_axil_bvalid;

    wire aw_accept = s_axil_awvalid && s_axil_awready;
    wire w_accept  = s_axil_wvalid  && s_axil_wready;
    wire have_aw   = aw_hold_valid || aw_accept;
    wire have_w    = w_hold_valid  || w_accept;
    wire write_commit = have_aw && have_w && !s_axil_bvalid;
    wire [11:0] write_addr = aw_hold_valid ? awaddr_hold : s_axil_awaddr;
    wire [31:0] write_data = w_hold_valid ? wdata_hold : s_axil_wdata;
    wire [3:0]  write_strb = w_hold_valid ? wstrb_hold : s_axil_wstrb;
    // 拒绝未按 4 字节对齐的访问，避免错误地址被别名到相邻寄存器。
    wire write_aligned = (write_addr[1:0] == 2'b00);
    wire coeff_write_addr = (write_addr >= ADDR_COEFF0) &&
                            (write_addr <= ADDR_COEFFN) &&
                            (write_addr[1:0] == 2'b00);
    wire [6:0] coeff_write_index = (write_addr - ADDR_COEFF0) >> 2;

    // --------------------- CSR/Stream 到 FIR 核心的复用 ------------------
    reg clear_core;
    wire core_s_ready;
    wire signed [31:0] core_m_data;
    wire core_m_valid;
    wire core_m_overflow;
    // DATA_IN 写入优先于外部流接口；该周期暂停 s_axis_tready，防止接收两个样本。
    wire csr_sample_attempt = write_commit && (write_addr == ADDR_DATA_IN);
    wire csr_sample_strb_ok = (write_strb[1:0] == 2'b11);
    wire csr_sample_request = csr_sample_attempt && csr_sample_strb_ok;
    wire csr_sample_valid = csr_sample_request && enable_reg && core_s_ready;
    wire signed [15:0] core_s_data = csr_sample_request ? write_data[15:0] : s_axis_tdata;
    wire core_s_valid = csr_sample_request ? csr_sample_valid : s_axis_tvalid;

    assign s_axis_tready = !csr_sample_request && core_s_ready;
    assign m_axis_tdata  = core_m_data;
    assign m_axis_tvalid = core_m_valid;
    assign data_enabled = enable_reg;
    assign data_clear_request = write_commit && write_aligned &&
                                (write_addr == ADDR_CTRL) && write_strb[0] &&
                                write_data[2];
    assign data_clear = clear_core;
    // sticky 状态始终保留事件；IRQ_EN 只屏蔽输出引脚，不会丢失状态。
    assign irq_done = done_sticky && irq_enable_reg[0];
    assign irq_ovf  = ovf_sticky && irq_enable_reg[1];

    fir_81tap_core #(
        .N_TAP(N_TAP), .W_IN(16), .W_COEF(16), .W_ACC(40), .W_OUT(32)
    ) u_core (
        .clk(aclk), .rstn(aresetn), .enable(enable_reg), .clear(clear_core),
        .coeff_flat(work_coeff_flat),
        .s_axis_tdata(core_s_data), .s_axis_tvalid(core_s_valid),
        .s_axis_tready(core_s_ready),
        .m_axis_tdata(core_m_data), .m_axis_tvalid(core_m_valid),
        .m_axis_tready(m_axis_tready), .m_axis_overflow(core_m_overflow)
    );

    // --------------------------- 读通道译码 ------------------------------
    // 当前读响应被主机接收前，不再接受下一条读请求。
    assign s_axil_arready = !s_axil_rvalid;
    wire coeff_read_addr = (s_axil_araddr >= ADDR_COEFF0) &&
                           (s_axil_araddr <= ADDR_COEFFN) &&
                           (s_axil_araddr[1:0] == 2'b00);
    wire [6:0] coeff_read_index = (s_axil_araddr - ADDR_COEFF0) >> 2;
    // BUSY 表示已使能且当前帧尚未产生 LEN 个输出；LEN=0 表示不做帧计数。
    wire busy_status = enable_reg && (length_reg != 16'd0) &&
                       (output_count < length_reg);

    integer index;
    // ---------------------- AXI-Lite、状态与中断时序 ---------------------
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            enable_reg    <= 1'b0;
            irq_enable_reg <= 2'b00;
            length_reg    <= 16'd0;
            output_count  <= 16'd0;
            done_sticky   <= 1'b0;
            ovf_sticky    <= 1'b0;
            last_output   <= 32'd0;
            awaddr_hold   <= 12'd0;
            aw_hold_valid <= 1'b0;
            wdata_hold    <= 32'd0;
            wstrb_hold    <= 4'd0;
            w_hold_valid  <= 1'b0;
            s_axil_bresp  <= 2'b00;
            s_axil_bvalid <= 1'b0;
            s_axil_rdata  <= 32'd0;
            s_axil_rresp  <= 2'b00;
            s_axil_rvalid <= 1'b0;
            clear_core    <= 1'b0;
            for (index = 0; index < N_TAP; index = index + 1) begin
                shadow_coeff[index] <= 16'sd0;
                work_coeff[index]   <= 16'sd0;
            end
        end else begin
            // clear_core 是单周期脉冲，只有写 CTRL.CLR 的周期才拉高。
            clear_core <= 1'b0;

            // 地址和数据可能分拍到达，分别锁存后再统一提交。
            if (aw_accept && !write_commit) begin
                awaddr_hold   <= s_axil_awaddr;
                aw_hold_valid <= 1'b1;
            end
            if (w_accept && !write_commit) begin
                wdata_hold   <= s_axil_wdata;
                wstrb_hold   <= s_axil_wstrb;
                w_hold_valid <= 1'b1;
            end

            // 完整的一次 CSR 写事务。
            if (write_commit) begin
                aw_hold_valid <= 1'b0;
                w_hold_valid  <= 1'b0;
                s_axil_bvalid <= 1'b1;
                s_axil_bresp  <= 2'b00;

                if (!write_aligned) begin
                    s_axil_bresp <= 2'b10;
                end else if (write_addr == ADDR_CTRL) begin
                    // CTRL：EN 是保持位；LOAD/CLR 是写 1 触发的动作。
                    if (write_strb[0]) begin
                        if (write_data[2] && data_busy) begin
                            // A clear during a live data transaction would
                            // change a blocked AXI response or drop W beats.
                            s_axil_bresp <= 2'b10;
                        end else begin
                            enable_reg <= write_data[0];
                            if (write_data[1]) begin
                                for (index = 0; index < N_TAP; index = index + 1)
                                    work_coeff[index] <= shadow_coeff[index];
                            end
                            if (write_data[2]) begin
                                clear_core   <= 1'b1;
                                output_count <= 16'd0;
                                done_sticky  <= 1'b0;
                                ovf_sticky   <= 1'b0;
                                last_output  <= 32'd0;
                            end
                        end
                    end
                end else if (write_addr == ADDR_STATUS) begin
                    // STATUS 的 DONE/OVF 为 W1C（Write 1 to Clear）。
                    if (write_strb[0]) begin
                        if (write_data[1]) done_sticky <= 1'b0;
                        if (write_data[2]) ovf_sticky  <= 1'b0;
                    end
                end else if (write_addr == ADDR_DATA_IN) begin
                    // 16-bit samples need both low byte lanes. An invalid
                    // strobe must not inject a sample into the stream.
                    if (!csr_sample_strb_ok || !enable_reg || !core_s_ready)
                        s_axil_bresp <= 2'b10;
                end else if (write_addr == ADDR_LEN) begin
                    // 已处理至少一个样本的活动帧中禁止改 LEN，避免 DONE 时刻不明确。
                    if (busy_status && (output_count != 16'd0)) begin
                        s_axil_bresp <= 2'b10;
                    end else begin
                        if (write_strb[0]) length_reg[7:0]  <= write_data[7:0];
                        if (write_strb[1]) length_reg[15:8] <= write_data[15:8];
                        output_count <= 16'd0;
                        done_sticky  <= 1'b0;
                    end
                end else if (write_addr == ADDR_IRQ_EN) begin
                    if (write_strb[0])
                        irq_enable_reg <= write_data[1:0];
                end else if (coeff_write_addr && (coeff_write_index < N_TAP)) begin
                    // 活动帧开始处理后禁止修改影子系数，使本帧配置保持稳定。
                    if (busy_status && (output_count != 16'd0)) begin
                        s_axil_bresp <= 2'b10;
                    end else begin
                        if (write_strb[0]) shadow_coeff[coeff_write_index][7:0]  <= write_data[7:0];
                        if (write_strb[1]) shadow_coeff[coeff_write_index][15:8] <= write_data[15:8];
                    end
                end else begin
                    s_axil_bresp <= 2'b10;
                end
            end

            if (s_axil_bvalid && s_axil_bready)
                s_axil_bvalid <= 1'b0;

            // CSR 读事务：合法地址返回 OKAY；未对齐或未定义地址返回 SLVERR。
            if (s_axil_arvalid && s_axil_arready) begin
                s_axil_rvalid <= 1'b1;
                s_axil_rresp  <= 2'b00;
                if (s_axil_araddr[1:0] != 2'b00) begin
                    s_axil_rdata <= 32'd0;
                    s_axil_rresp <= 2'b10;
                end else case (s_axil_araddr)
                    ADDR_CTRL:     s_axil_rdata <= {31'd0, enable_reg};
                    ADDR_STATUS:   s_axil_rdata <= {29'd0, ovf_sticky, done_sticky, busy_status};
                    ADDR_DATA_OUT: s_axil_rdata <= last_output;
                    ADDR_LEN:      s_axil_rdata <= {16'd0, length_reg};
                    ADDR_IRQ_EN:   s_axil_rdata <= {30'd0, irq_enable_reg};
                    default: begin
                        if (coeff_read_addr && (coeff_read_index < N_TAP))
                            s_axil_rdata <= {{16{shadow_coeff[coeff_read_index][15]}},
                                            shadow_coeff[coeff_read_index]};
                        else begin
                            s_axil_rdata <= 32'd0;
                            s_axil_rresp <= 2'b10;
                        end
                    end
                endcase
            end else if (s_axil_rvalid && s_axil_rready) begin
                s_axil_rvalid <= 1'b0;
            end

            // 只有输出真正握手后才计数、保存最近结果并更新 sticky 状态。
            if (core_m_valid && m_axis_tready) begin
                last_output <= core_m_data;
                if (length_reg != 16'd0) begin
                    if ((output_count + 1'b1) >= length_reg) begin
                        done_sticky <= 1'b1;
                        output_count <= length_reg;
                    end else begin
                        output_count <= output_count + 1'b1;
                    end
                end
                if (core_m_overflow)
                    ovf_sticky <= 1'b1;
            end
        end
    end
endmodule
