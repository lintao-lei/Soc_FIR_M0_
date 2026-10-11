`timescale 1ns / 1ps

module uart_tx_byte#(
    parameter integer CLKS_PER_BIT = 434
)(
    input wire          clk,
    input wire          reset_n,
    
    input wire [7:0]    tx_data,
    input wire          tx_valid,
    output wire         tx_ready,
    output reg          uart_tx,
    output reg          tx_done 
);

    localparam [1:0] ST_IDLE  = 2'd0;
    localparam [1:0] ST_START = 2'd1;
    localparam [1:0] ST_DATA  = 2'd2;
    localparam [1:0] ST_STOP  = 2'd3;
    
    reg [1:0]  state;
    reg [7:0]  data_reg;
    reg [15:0] ticks;
    reg [2:0]  bit_index;
    
    assign tx_ready = reset_n && (state == ST_IDLE);
    always@(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            state <= ST_IDLE;
            data_reg <= 8'd0;
            ticks <= 16'd0;
            bit_index <= 3'd0;
            uart_tx <= 1'b1;
            tx_done <= 1'b0;
        end else begin
            tx_done <= 1'b0;
            
            case(state)
                ST_IDLE:begin
                    uart_tx <= 1'b1;
                    if(tx_valid && tx_ready) begin
                        uart_tx <= 1'b0;
                        data_reg <= tx_data;
                        ticks <= CLKS_PER_BIT-1;
                        state <= ST_START;
                    end  
                end
                
                ST_START: begin
                    if(ticks == 0)begin
                        uart_tx <= data_reg[0];
                        bit_index <= 3'd0;
                        ticks <= CLKS_PER_BIT-1;
                        state <= ST_DATA;
                    end else begin
                        ticks <= ticks - 1'b1;
                    end
                end
                
                ST_DATA: begin
                    if(ticks == 0)begin
                        ticks <= CLKS_PER_BIT-1;
                        if(bit_index == 3'd7) begin
                            uart_tx <= 1'b1;
                            state <= ST_STOP;
                        end else begin                          
                            bit_index <= bit_index + 1'b1;
                            uart_tx <= data_reg[bit_index+1'b1];
                        end
                    end else begin
                        ticks <= ticks - 1'b1;
                    end
                end
                
                ST_STOP:begin
                    if(ticks == 0) begin
                        tx_done <= 1'b1;
                        state <= ST_IDLE;
                    end else begin
                        ticks <= ticks - 1'b1;
                    end
                end
                
                default : begin
                    state <= ST_IDLE;
                end
                
            endcase
        end
    end
    
endmodule
