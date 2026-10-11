`timescale 1ns / 1ps

// -----------------------------------------------------------------------------
// 六通道 DMA 轮询调度器
//
// 本模块不保存 DMA 的源地址、目标地址和长度，也不直接发送 AXI 请求。
// 它只负责：
//   1. 从 channel_pending[5:0] 中选择一个等待执行的通道；
//   2. 给寄存器核心发送 scheduler_claim，把该通道变成 BUSY；
//   3. 给 DMA 搬运执行器发送一个周期的 engine_start；
//   4. 等待执行器返回 engine_done；
//   5. 通过 scheduler_complete/scheduler_error 把结果报告给寄存器核心。
//
// 调度方式采用 Round-Robin（轮询）：
//   如果上一次执行通道 2，下一次就按照 3、4、5、0、1、2 的顺序查找。
//   这样可以避免固定优先级导致高编号通道长期得不到执行。
//
// 该版本一次只执行一个 DMA 通道，不支持通道抢占。
// -----------------------------------------------------------------------------

module dma6_scheduler (
    input  wire       clk,
    input  wire       reset_n,
    
    input wire scheduler_enable,

    // 来自 dma6_register_file：每一位表示对应通道是否有等待任务。
    input  wire [5:0] channel_pending,

    // 送给 dma6_register_file：当前正在选择或执行的通道编号。
    output wire [2:0] scheduler_channel,

    // 送给 dma6_register_file：领取选中任务的单周期脉冲。
    output wire       scheduler_claim,

    // 送给 DMA 搬运执行器：启动一次搬运任务的单周期脉冲。
    output wire       engine_start,

    // 来自 DMA 搬运执行器。
    input  wire       engine_busy,
    input  wire       engine_done,
    input  wire       engine_error,

    // 送给 dma6_register_file：任务执行结果。
    // scheduler_complete 是单周期脉冲；scheduler_error 与它同时有效。
    output wire       scheduler_complete,
    output wire       scheduler_error
);

    // -------------------------------------------------------------------------
    // 调度器状态机
    // -------------------------------------------------------------------------

    localparam [1:0] ST_IDLE   = 2'd0; // 查找等待任务
    localparam [1:0] ST_LAUNCH = 2'd1; // 领取通道并启动执行器
    localparam [1:0] ST_WAIT   = 2'd2; // 等待执行器完成
    localparam [1:0] ST_REPORT = 2'd3; // 向寄存器核心报告结果

    reg [1:0] state;

    // 当前任务所属的通道。
    // 从选择任务开始到报告结果结束，这个寄存器必须保持不变。
    reg [2:0] active_channel_reg;

    // 上一次完成调度的通道，用于确定下一次轮询的起点。
    reg [2:0] last_grant_reg;

    // 在 engine_done 有效时锁存 engine_error，供下一状态报告。
    reg result_error_reg;

    // 轮询组合逻辑给出的选择结果。
    reg       select_valid;
    reg [2:0] select_channel;

    // -------------------------------------------------------------------------
    // Round-Robin 轮询选择逻辑
    //
    // 每个 case 分支都从"上一次通道的下一个通道"开始查找，
    // 最后才回到上一次执行的通道。
    // -------------------------------------------------------------------------

    always @(*) begin
        select_valid   = 1'b0;
        select_channel = 3'd0;

        case (last_grant_reg)
            // 上次是通道0：本次按 1、2、3、4、5、0 查找。
            3'd0: begin
                if (channel_pending[1]) begin
                    select_valid   = 1'b1;
                    select_channel = 3'd1;
                end else if (channel_pending[2]) begin
                    select_valid   = 1'b1;
                    select_channel = 3'd2;
                end else if (channel_pending[3]) begin
                    select_valid   = 1'b1;
                    select_channel = 3'd3;
                end else if (channel_pending[4]) begin
                    select_valid   = 1'b1;
                    select_channel = 3'd4;
                end else if (channel_pending[5]) begin
                    select_valid   = 1'b1;
                    select_channel = 3'd5;
                end else if (channel_pending[0]) begin
                    select_valid   = 1'b1;
                    select_channel = 3'd0;
                end
            end

            // 上次是通道1：本次按 2、3、4、5、0、1 查找。
            3'd1: begin
                if (channel_pending[2]) begin
                    select_valid   = 1'b1;
                    select_channel = 3'd2;
                end else if (channel_pending[3]) begin
                    select_valid   = 1'b1;
                    select_channel = 3'd3;
                end else if (channel_pending[4]) begin
                    select_valid   = 1'b1;
                    select_channel = 3'd4;
                end else if (channel_pending[5]) begin
                    select_valid   = 1'b1;
                    select_channel = 3'd5;
                end else if (channel_pending[0]) begin
                    select_valid   = 1'b1;
                    select_channel = 3'd0;
                end else if (channel_pending[1]) begin
                    select_valid   = 1'b1;
                    select_channel = 3'd1;
                end
            end

            // 上次是通道2：本次按 3、4、5、0、1、2 查找。
            3'd2: begin
                if (channel_pending[3]) begin
                    select_valid   = 1'b1;
                    select_channel = 3'd3;
                end else if (channel_pending[4]) begin
                    select_valid   = 1'b1;
                    select_channel = 3'd4;
                end else if (channel_pending[5]) begin
                    select_valid   = 1'b1;
                    select_channel = 3'd5;
                end else if (channel_pending[0]) begin
                    select_valid   = 1'b1;
                    select_channel = 3'd0;
                end else if (channel_pending[1]) begin
                    select_valid   = 1'b1;
                    select_channel = 3'd1;
                end else if (channel_pending[2]) begin
                    select_valid   = 1'b1;
                    select_channel = 3'd2;
                end
            end

            // 上次是通道3：本次按 4、5、0、1、2、3 查找。
            3'd3: begin
                if (channel_pending[4]) begin
                    select_valid   = 1'b1;
                    select_channel = 3'd4;
                end else if (channel_pending[5]) begin
                    select_valid   = 1'b1;
                    select_channel = 3'd5;
                end else if (channel_pending[0]) begin
                    select_valid   = 1'b1;
                    select_channel = 3'd0;
                end else if (channel_pending[1]) begin
                    select_valid   = 1'b1;
                    select_channel = 3'd1;
                end else if (channel_pending[2]) begin
                    select_valid   = 1'b1;
                    select_channel = 3'd2;
                end else if (channel_pending[3]) begin
                    select_valid   = 1'b1;
                    select_channel = 3'd3;
                end
            end

            // 上次是通道4：本次按 5、0、1、2、3、4 查找。
            3'd4: begin
                if (channel_pending[5]) begin
                    select_valid   = 1'b1;
                    select_channel = 3'd5;
                end else if (channel_pending[0]) begin
                    select_valid   = 1'b1;
                    select_channel = 3'd0;
                end else if (channel_pending[1]) begin
                    select_valid   = 1'b1;
                    select_channel = 3'd1;
                end else if (channel_pending[2]) begin
                    select_valid   = 1'b1;
                    select_channel = 3'd2;
                end else if (channel_pending[3]) begin
                    select_valid   = 1'b1;
                    select_channel = 3'd3;
                end else if (channel_pending[4]) begin
                    select_valid   = 1'b1;
                    select_channel = 3'd4;
                end
            end

            // 上次是通道5：本次按 0、1、2、3、4、5 查找。
            3'd5: begin
                if (channel_pending[0]) begin
                    select_valid   = 1'b1;
                    select_channel = 3'd0;
                end else if (channel_pending[1]) begin
                    select_valid   = 1'b1;
                    select_channel = 3'd1;
                end else if (channel_pending[2]) begin
                    select_valid   = 1'b1;
                    select_channel = 3'd2;
                end else if (channel_pending[3]) begin
                    select_valid   = 1'b1;
                    select_channel = 3'd3;
                end else if (channel_pending[4]) begin
                    select_valid   = 1'b1;
                    select_channel = 3'd4;
                end else if (channel_pending[5]) begin
                    select_valid   = 1'b1;
                    select_channel = 3'd5;
                end
            end

            // last_grant_reg 出现非法值时，从通道0开始查找。
            default: begin
                if (channel_pending[0]) begin
                    select_valid   = 1'b1;
                    select_channel = 3'd0;
                end else if (channel_pending[1]) begin
                    select_valid   = 1'b1;
                    select_channel = 3'd1;
                end else if (channel_pending[2]) begin
                    select_valid   = 1'b1;
                    select_channel = 3'd2;
                end else if (channel_pending[3]) begin
                    select_valid   = 1'b1;
                    select_channel = 3'd3;
                end else if (channel_pending[4]) begin
                    select_valid   = 1'b1;
                    select_channel = 3'd4;
                end else if (channel_pending[5]) begin
                    select_valid   = 1'b1;
                    select_channel = 3'd5;
                end
            end
        endcase
    end

    // -------------------------------------------------------------------------
    // 对外输出
    // -------------------------------------------------------------------------

    // 任务执行期间始终输出锁存后的活动通道号。
    assign scheduler_channel = active_channel_reg;

    // ST_LAUNCH 只持续一个周期，所以 claim 和 start 都是单周期脉冲。
    assign scheduler_claim = reset_n && (state == ST_LAUNCH);
    assign engine_start    = reset_n && (state == ST_LAUNCH);

    // ST_REPORT 只持续一个周期，所以 complete 是单周期脉冲。
    assign scheduler_complete = reset_n && (state == ST_REPORT);

    // error 只在 complete 有效的报告周期中才对外有效。
    assign scheduler_error = reset_n &&
                             (state == ST_REPORT) &&
                             result_error_reg;

    // -------------------------------------------------------------------------
    // 时序状态机
    // -------------------------------------------------------------------------

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state              <= ST_IDLE;
            active_channel_reg <= 3'd0;

            // 复位后把上一次通道设为5，使第一次轮询从通道0开始。
            last_grant_reg     <= 3'd5;

            result_error_reg   <= 1'b0;
        end else begin
            case (state)
                // -------------------------------------------------------------
                // 空闲状态：等待执行器空闲，并寻找一个 PENDING 通道。
                // -------------------------------------------------------------
                ST_IDLE: begin
                    result_error_reg <= 1'b0;

                    if (scheduler_enable&&
                        !engine_busy && 
                        select_valid) begin
                        active_channel_reg <= select_channel;
                        state              <= ST_LAUNCH;
                    end
                end

                // -------------------------------------------------------------
                // 启动状态：
                // 此状态下 scheduler_claim 和 engine_start 同时为1。
                // 在本周期末，寄存器核心进入 BUSY，执行器锁存任务参数。
                // -------------------------------------------------------------
                ST_LAUNCH: begin
                    state <= ST_WAIT;
                end

                // -------------------------------------------------------------
                // 等待状态：
                // 在 engine_done 之前不能重新选择其他通道。
                // -------------------------------------------------------------
                ST_WAIT: begin
                    if (engine_done) begin
                        result_error_reg <= engine_error;
                        state            <= ST_REPORT;
                    end
                end

                // -------------------------------------------------------------
                // 报告状态：
                // 此状态下 scheduler_complete 为1，并同时报告错误状态。
                // 报告完毕后回到 IDLE，继续查找下一项任务。
                // -------------------------------------------------------------
                ST_REPORT: begin
                    last_grant_reg <= active_channel_reg;
                    state          <= ST_IDLE;
                end

                default: begin
                    state              <= ST_IDLE;
                    active_channel_reg <= 3'd0;
                    last_grant_reg     <= 3'd5;
                    result_error_reg   <= 1'b0;
                end
            endcase
        end
    end

endmodule


