`timescale 1ns/1ps

// ============================================================================
// 81 抽头有符号定点 FIR 核心
// ----------------------------------------------------------------------------
// 结构：全并行转置型 FIR（Transposed Form）。每个抽头各使用一个乘法器，
//      新样本被接收时，所有乘法和级间累加器同时推进一次。
// 数据格式：输入和系数均为 Q15，即实际值约等于“有符号整数 / 2^15”。
// 计算公式：y[n] = sum(k=0..N_TAP-1) { h[k] * x[n-k] }。
// 吞吐率：流水线充满且下游不施加背压时，每个时钟可接收一个新样本。
// 握手规则：只有 valid=1 且 ready=1 的时钟沿才真正传输一个样本。
// ============================================================================
module fir_81tap_core #(
    // 以下参数允许在测试时改变抽头数和位宽；正式配置为 81/16/16/40/32。
    parameter integer N_TAP  = 81,
    parameter integer W_IN   = 16,
    parameter integer W_COEF = 16,
    parameter integer W_ACC  = 40,
    parameter integer W_OUT  = 32
)(
    // 时钟、低有效同步复位、运行使能和状态清空
    input  wire                         clk,
    input  wire                         rstn,
    input  wire                         enable,
    input  wire                         clear,
    // 按 tap0、tap1……顺序拼接的全部 Q15 系数
    input  wire [N_TAP*W_COEF-1:0]      coeff_flat,
    // AXI-Stream 风格输入端口
    input  wire signed [W_IN-1:0]       s_axis_tdata,
    input  wire                         s_axis_tvalid,
    output wire                         s_axis_tready,
    // AXI-Stream 风格输出端口；overflow 与当前输出样本同步
    output reg  signed [W_OUT-1:0]      m_axis_tdata,
    output reg                          m_axis_tvalid,
    input  wire                         m_axis_tready,
    output reg                          m_axis_overflow
);
    // Q15 乘法后需要右移 15 位，才能恢复到原来的数值尺度。
    localparam integer Q_SHIFT = 15;
    localparam integer W_PROD = W_IN + W_COEF;

    // tap_coeff：拆开的单个系数；tap_product：当前输入与各系数的乘积。
    // tap_state：转置型结构的级间累加状态，保存历史样本产生的部分和。
    wire signed [W_COEF-1:0] tap_coeff [0:N_TAP-1];
    wire signed [W_PROD-1:0] tap_product [0:N_TAP-1];
    wire signed [W_ACC-1:0] tap_product_ext [0:N_TAP-1];
    reg  signed [W_ACC-1:0] tap_state [0:N_TAP-2];
    reg  signed [W_ACC-1:0] result_acc;
    reg                         result_valid;
    reg                         result_overflow;

    genvar tap_index;
    generate
        // 展开 N_TAP 路并行乘法。乘积先做符号扩展，再进入 40 位累加链，
        // 避免 16x16 位乘积在多抽头求和时过早溢出。
        for (tap_index = 0; tap_index < N_TAP; tap_index = tap_index + 1) begin : g_taps
            assign tap_coeff[tap_index] = coeff_flat[tap_index*W_COEF +: W_COEF];
            assign tap_product[tap_index] = $signed(s_axis_tdata) *
                                            $signed(tap_coeff[tap_index]);
            assign tap_product_ext[tap_index] =
                {{(W_ACC-W_PROD){tap_product[tap_index][W_PROD-1]}},
                  tap_product[tap_index]};
        end
    endgenerate

    // 第 0 抽头乘积与第一级历史状态相加，构成本次样本的完整滤波结果。
    wire signed [W_ACC-1:0] output_acc = tap_product_ext[0] + tap_state[0];
    // 两级弹性流水控制：输出被消费或为空时才能推进结果级；结果级有空间时
    // 才允许接收输入。下游拉低 m_axis_tready 时，数据和内部状态都会保持。
    wire output_ready = !m_axis_tvalid || m_axis_tready;
    wire result_ready = !result_valid || output_ready;
    assign s_axis_tready = enable && result_ready && !clear;

    // 将宽累加结果从 Q30 量级舍入回 Q15 量级，并限制在 W_OUT 位范围内。
    // 正负数分别处理，使舍入方向关于零点对称；越界时输出最大/最小饱和值。
    function [W_OUT-1:0] quantize_and_saturate;
        input signed [W_ACC-1:0] value;
        reg signed [W_ACC:0] value_ext;
        reg signed [W_ACC:0] magnitude;
        reg signed [W_ACC:0] rounded;
        reg signed [W_ACC:0] round_bias;
        reg signed [W_ACC:0] out_max;
        reg signed [W_ACC:0] out_min;
        reg signed [W_ACC:0] one;
        begin
            value_ext  = {value[W_ACC-1], value};
            one        = {{W_ACC{1'b0}}, 1'b1};
            round_bias = one <<< (Q_SHIFT-1);
            out_max    = (one <<< (W_OUT-1)) - one;
            out_min    = -(one <<< (W_OUT-1));

            if (value_ext < 0) begin
                magnitude = -value_ext;
                rounded = -((magnitude + round_bias) >>> Q_SHIFT);
            end else begin
                rounded = (value_ext + round_bias) >>> Q_SHIFT;
            end

            if (rounded > out_max)
                quantize_and_saturate = {1'b0, {(W_OUT-1){1'b1}}};
            else if (rounded < out_min)
                quantize_and_saturate = {1'b1, {(W_OUT-1){1'b0}}};
            else
                quantize_and_saturate = rounded[W_OUT-1:0];
        end
    endfunction

    // 与上面的量化函数使用完全相同的舍入规则，只返回是否发生饱和。
    function quantize_overflow;
        input signed [W_ACC-1:0] value;
        reg signed [W_ACC:0] value_ext;
        reg signed [W_ACC:0] magnitude;
        reg signed [W_ACC:0] rounded;
        reg signed [W_ACC:0] round_bias;
        reg signed [W_ACC:0] out_max;
        reg signed [W_ACC:0] out_min;
        reg signed [W_ACC:0] one;
        begin
            value_ext  = {value[W_ACC-1], value};
            one        = {{W_ACC{1'b0}}, 1'b1};
            round_bias = one <<< (Q_SHIFT-1);
            out_max    = (one <<< (W_OUT-1)) - one;
            out_min    = -(one <<< (W_OUT-1));

            if (value_ext < 0) begin
                magnitude = -value_ext;
                rounded = -((magnitude + round_bias) >>> Q_SHIFT);
            end else begin
                rounded = (value_ext + round_bias) >>> Q_SHIFT;
            end
            quantize_overflow = (rounded > out_max) || (rounded < out_min);
        end
    endfunction

    integer index;
    // 使用同步复位有利于 Vivado 将累加寄存器映射进 DSP48 流水寄存器。
    // rstn 虽名为低有效复位，但这里只在时钟上升沿采样。
    always @(posedge clk) begin
        if (!rstn) begin
            for (index = 0; index < N_TAP-1; index = index + 1)
                tap_state[index] <= {W_ACC{1'b0}};
            result_acc        <= {W_ACC{1'b0}};
            result_valid      <= 1'b0;
            result_overflow   <= 1'b0;
            m_axis_tdata    <= {W_OUT{1'b0}};
            m_axis_tvalid   <= 1'b0;
            m_axis_overflow <= 1'b0;
        end else if (clear) begin
            // clear 清空历史状态，相当于从全零延迟线开始一帧新数据。
            for (index = 0; index < N_TAP-1; index = index + 1)
                tap_state[index] <= {W_ACC{1'b0}};
            result_acc        <= {W_ACC{1'b0}};
            result_valid      <= 1'b0;
            result_overflow   <= 1'b0;
            m_axis_tdata    <= {W_OUT{1'b0}};
            m_axis_tvalid   <= 1'b0;
            m_axis_overflow <= 1'b0;
        end else begin
            // 输出级有空间时，将上一拍保存在 result_acc 的结果量化后送出。
            if (output_ready) begin
                if (result_valid) begin
                    m_axis_tdata     <= quantize_and_saturate(result_acc);
                    m_axis_tvalid    <= 1'b1;
                    m_axis_overflow  <= result_overflow;
                end else begin
                    m_axis_tvalid    <= 1'b0;
                    m_axis_overflow  <= 1'b0;
                end
            end

            // 中间结果级有空间时，才允许整条转置型累加链推进。
            if (result_ready) begin
            if (s_axis_tvalid && s_axis_tready) begin
                // 接收到一个新样本：第 k 级写入“当前样本×h[k+1] + 后级历史部分和”。
                // 最后一级只保存当前样本与最后一个系数的乘积。
                for (index = 0; index < N_TAP-2; index = index + 1)
                    tap_state[index] <= tap_product_ext[index+1] + tap_state[index+1];
                tap_state[N_TAP-2] <= tap_product_ext[N_TAP-1];
                    result_acc      <= output_acc;
                    result_valid    <= 1'b1;
                    result_overflow <= quantize_overflow(output_acc);
            end else begin
                    result_valid    <= 1'b0;
                    result_overflow <= 1'b0;
                end
            end
        end
    end
endmodule
