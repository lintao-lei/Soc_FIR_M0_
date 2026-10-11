`timescale 1ns/1ps
//ʱ�Ӻ͸�λ
module soc_clock_reset (
    input  wire clk_board,
    input  wire reset_n,
    output wire clk_sys,
    output wire reset_sys_n
);

    // FRAMEWORK NOTE:
    // clk_board is passed through for now. Replace this assignment with a
    // Clocking Wizard/MMCM instance after the exact board oscillator is known.
    assign clk_sys = clk_board;

    // Asynchronous assertion, synchronous release.
    reg [1:0] reset_pipe;
    always @(posedge clk_sys or negedge reset_n) begin
        if (!reset_n)
            reset_pipe <= 2'b00;
        else
            reset_pipe <= {reset_pipe[0], 1'b1};
    end

    assign reset_sys_n = reset_pipe[1];

endmodule
