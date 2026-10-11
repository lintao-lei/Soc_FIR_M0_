`timescale 1ns / 1ps

module uart_rx_byte#(
    parameter integer CLKS_PER_BIT = 434
 )(
    input wire          clk,
    input wire          reset_n,
    
    input wire          uart_rx,
    output reg [7:0]    rx_data,
    output reg          rx_valid,
    input wire          rx_ready,
    
    output reg          frame_error          
 );
 
    localparam [2:0]  ST_IDLE  = 3'd0;
    localparam [2:0]  ST_START = 3'd1;
    localparam [2:0]  ST_DATA  = 3'd2;
    localparam [2:0]  ST_STOP  = 3'd3;
    localparam [2:0]  ST_HOLD  = 3'd4;
    localparam [2:0]  ST_WAIT_HIGH  = 3'd5;
    
    localparam integer HALF_BIT = CLKS_PER_BIT / 2;
    
    reg rx_meta;
    reg rx_sync;
    
    reg [2:0] state;
    reg [15:0] ticks;
    reg [7:0] data_reg;
    reg [2:0] bit_index;
    
    always@(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            rx_meta <= 1'b1;
            rx_sync <= 1'b1;
        end else begin
            rx_meta <= uart_rx;
            rx_sync <= rx_meta;
        end
    end
    
    always@(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            state <= ST_IDLE;
            ticks <= 16'd0;
            data_reg <= 8'd0;
            rx_data <= 8'd0;
            bit_index <= 3'd0;
            rx_valid <= 1'b0;
            frame_error <= 1'b0;
        end else begin
            frame_error <= 1'b0;
            
            case(state)
                ST_IDLE:begin
                    if(rx_sync == 1'b0)begin              
                        ticks <= HALF_BIT - 1;
                        state <= ST_START; 
                   end
                end
                
                ST_START: begin
                    if(ticks == 0) begin
                        if(rx_sync == 1'b0) begin
                            ticks <=  CLKS_PER_BIT- 1'b1;
                            bit_index <= 3'd0;
                            state <= ST_DATA;   
                        end else begin
                            state <= ST_IDLE;
                        end
                    end else begin
                        ticks <= ticks - 1'b1;
                    end
                end
                
                ST_DATA:begin
                    if(ticks == 0) begin
                        data_reg[bit_index] <= rx_sync;
                        ticks <= CLKS_PER_BIT- 1'b1;
                        
                        if(bit_index == 3'd7)begin
                            state <= ST_STOP;
                        end else begin
                            bit_index <= bit_index + 1'b1;
                        end
                    end else begin
                        ticks <= ticks - 1'b1;
                    end
                end
                
                ST_STOP: begin
                    if(ticks == 0) begin
                        if(rx_sync == 1'b1) begin
                            rx_data <= data_reg;
                            rx_valid <= 1'b1;
                            state <= ST_HOLD;
                        end else begin
                            frame_error <= 1'b1;
                            state <= ST_WAIT_HIGH;
                        end
                    end else begin
                        ticks <= ticks - 1'b1;
                    end
                end
                
                ST_HOLD: begin
                    if (rx_valid && rx_ready) begin
                        rx_valid <= 1'b0;
                        state    <= ST_IDLE;
                    end
                end
                
                ST_WAIT_HIGH: begin
                    if (rx_sync == 1'b1)
                        state <= ST_IDLE;
                end
                
                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end
endmodule
