`timescale 1ns/1ps

// ============================================================================
// FIR 高吞吐 AXI4 数据窗口
// ----------------------------------------------------------------------------
// 本模块只搬运样本，不负责使能、系数、帧长度等控制；控制面在 fir_81tap_axi。
// AXI 写突发：每个 32 位 beat 的低 16 位作为一个有符号 Q15 输入样本。
// AXI 读突发：从结果 FIFO 依次读出 FIR 的 32 位输出。
// 支持 FIXED/INCR 突发，数据宽度固定为 4 字节；非法请求返回 SLVERR。
// 典型用途：CPU 或 DMA 通过该窗口批量送入样本并批量取回结果。
// ============================================================================
module axi_fir_data #(
    // FIFO_DEPTH 必须是大于等于 2 的 2 次幂，FIFO_AW 默认为其地址位宽。
    parameter integer FIFO_DEPTH = 32,
    parameter integer FIFO_AW = $clog2(FIFO_DEPTH)
)(
    // AXI4 写地址、写数据和写响应通道
    input  wire        aclk,
    input  wire        aresetn,
    input  wire [31:0] s_axi_awaddr,
    input  wire [7:0]  s_axi_awlen,
    input  wire [2:0]  s_axi_awsize,
    input  wire [1:0]  s_axi_awburst,
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wlast,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,
    output reg  [1:0]  s_axi_bresp,
    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,
    // AXI4 读地址和读数据通道
    input  wire [31:0] s_axi_araddr,
    input  wire [7:0]  s_axi_arlen,
    input  wire [2:0]  s_axi_arsize,
    input  wire [1:0]  s_axi_arburst,
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,
    output wire [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output wire        s_axi_rlast,
    output wire        s_axi_rvalid,
    input  wire        s_axi_rready,

    // 连接 fir_81tap_axi 的 AXI-Stream 样本端口
    output wire signed [15:0] fir_s_tdata,
    output wire               fir_s_tvalid,
    input  wire               fir_s_tready,
    input  wire signed [31:0] fir_m_tdata,
    input  wire               fir_m_tvalid,
    output wire               fir_m_tready,

    // The control block uses these signals to make clear an atomic boundary.
    input  wire               fir_enabled,
    input  wire               clear_request,
    input  wire               clear_data,
    output wire               data_busy
);
    // 写/读突发状态：len 按 AXI 规则表示“拍数减 1”，count 从 0 计数。
    reg write_active;
    reg [7:0] write_count;
    reg [7:0] write_len;
    reg write_error;

    reg read_active;
    reg [7:0] read_count;
    reg [7:0] read_len;
    reg read_error;

    // FIR 结果先进入同步 FIFO，解耦 FIR 输出节拍和 AXI 读取节拍。
    reg [31:0] result_fifo [0:FIFO_DEPTH-1];
    reg [FIFO_AW-1:0] wr_ptr;
    reg [FIFO_AW-1:0] rd_ptr;
    reg [FIFO_AW:0] fifo_count;

    // 指针依靠自然溢出回绕，因此 FIFO 深度必须为 2 次幂。
    wire fifo_config_ok = (FIFO_DEPTH >= 2) &&
                          ((1 << FIFO_AW) == FIFO_DEPTH);
    // 数据窗口只接受偏移 0、32 位 beat、FIXED 或 INCR 类型的请求。
    wire write_request_ok = fifo_config_ok &&
                            (s_axi_awaddr[11:0] == 12'h000) &&
                            (s_axi_awsize == 3'd2) &&
                            ((s_axi_awburst == 2'b00) ||
                             (s_axi_awburst == 2'b01));
    wire read_request_ok = fifo_config_ok &&
                           (s_axi_araddr[11:0] == 12'h000) &&
                           (s_axi_arsize == 3'd2) &&
                           ((s_axi_arburst == 2'b00) ||
                            (s_axi_arburst == 2'b01));
    wire fifo_empty = (fifo_count == 0);
    wire fifo_full = (fifo_count == FIFO_DEPTH);
    // push/pop 均严格遵循 valid/ready 握手；同拍一进一出时数量不变。
    wire push_result = fir_m_tvalid && fir_m_tready;
    wire pop_result = s_axi_rvalid && s_axi_rready;
    wire pop_fifo = pop_result && !read_error;
    assign data_busy = write_active || read_active || s_axi_bvalid;

    // ------------------------------ 写通道 -------------------------------
    // 一个突发完成且写响应被接收前，不接受新的写地址。
    assign s_axi_awready = !write_active && !s_axi_bvalid &&
                           !clear_request && !clear_data;
    assign fir_s_tdata = s_axi_wdata[15:0];
    // 一个完整的 16 位样本必须同时写低两个字节通道。
    wire write_data_ok = (s_axi_wstrb[1:0] == 2'b11);
    assign fir_s_tvalid = write_active && !write_error && fir_enabled &&
                          write_data_ok && s_axi_wvalid && !clear_data;
    assign s_axi_wready = write_active &&
                          (write_error || !fir_enabled || !write_data_ok ||
                           fir_s_tready);

    // ------------------------------ 读通道 -------------------------------
    assign s_axi_arready = !read_active && !clear_request && !clear_data;
    assign s_axi_rdata = read_error ? 32'd0 : result_fifo[rd_ptr];
    assign s_axi_rresp = read_error ? 2'b10 : 2'b00;
    assign s_axi_rlast = read_active && (read_count == read_len);
    assign s_axi_rvalid = read_active && (read_error || !fifo_empty);

    // FIFO 满时向 FIR 施加背压；若本拍同时弹出一个元素，仍可接收新结果。
    assign fir_m_tready = !clear_data && (!fifo_full || pop_fifo);

    // ------------------------- 突发控制与 FIFO 时序 ----------------------
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            write_active <= 1'b0;
            write_count <= 8'd0;
            write_len <= 8'd0;
            write_error <= 1'b0;
            s_axi_bresp <= 2'b00;
            s_axi_bvalid <= 1'b0;
            read_active <= 1'b0;
            read_count <= 8'd0;
            read_len <= 8'd0;
            read_error <= 1'b0;
            wr_ptr <= {FIFO_AW{1'b0}};
            rd_ptr <= {FIFO_AW{1'b0}};
            fifo_count <= {(FIFO_AW+1){1'b0}};
        end else begin
            // 锁存一次写突发的长度和合法性；即使非法，也消费后续数据并返回错误。
            if (s_axi_awvalid && s_axi_awready) begin
                write_active <= 1'b1;
                write_count <= 8'd0;
                write_len <= s_axi_awlen;
                // A disabled FIR cannot accept samples. Drain exactly the
                // declared number of W beats and report SLVERR instead.
                write_error <= !write_request_ok || !fir_enabled;
            end

            // 每个成功握手的写 beat 对应一个 FIR 输入样本。
            if (s_axi_wvalid && s_axi_wready) begin
                if (!fir_enabled || !write_data_ok ||
                    (s_axi_wlast != (write_count == write_len)))
                    write_error <= 1'b1;

                // WLAST is checked, but an early WLAST may not truncate the
                // AWLEN-declared transaction.
                if (write_count == write_len) begin
                    write_active <= 1'b0;
                    s_axi_bvalid <= 1'b1;
                    s_axi_bresp <= (write_error ||
                                    !fir_enabled || !write_data_ok ||
                                    !s_axi_wlast) ?
                                   2'b10 : 2'b00;
                end else begin
                    write_count <= write_count + 1'b1;
                end
            end
            if (s_axi_bvalid && s_axi_bready)
                s_axi_bvalid <= 1'b0;

            // 锁存一次读突发；合法读在 FIFO 非空时给出数据，非法读直接返回 SLVERR。
            if (s_axi_arvalid && s_axi_arready) begin
                read_active <= 1'b1;
                read_count <= 8'd0;
                read_len <= s_axi_arlen;
                read_error <= !read_request_ok;
            end
            if (pop_result) begin
                if (!read_error)
                    rd_ptr <= rd_ptr + 1'b1;
                if (s_axi_rlast) begin
                    read_active <= 1'b0;
                    read_error <= 1'b0;
                end else begin
                    read_count <= read_count + 1'b1;
                end
            end

            // FIR 输出握手后写入 FIFO。
            if (push_result) begin
                result_fifo[wr_ptr] <= fir_m_tdata;
                wr_ptr <= wr_ptr + 1'b1;
            end

            // 统一更新 FIFO 元素数量，正确处理同一拍同时 push 和 pop。
            case ({push_result, pop_fifo})
                2'b10: fifo_count <= fifo_count + 1'b1;
                2'b01: fifo_count <= fifo_count - 1'b1;
                default: fifo_count <= fifo_count;
            endcase

            // CTRL.CLR is accepted only while data_busy=0. The pulse arrives
            // after the CSR handshake; no new AW/AR may enter during either
            // cycle. FIFO storage need not be zeroed because count=0 hides it.
            if (clear_data) begin
                wr_ptr <= {FIFO_AW{1'b0}};
                rd_ptr <= {FIFO_AW{1'b0}};
                fifo_count <= {(FIFO_AW+1){1'b0}};
            end
        end
    end
endmodule
