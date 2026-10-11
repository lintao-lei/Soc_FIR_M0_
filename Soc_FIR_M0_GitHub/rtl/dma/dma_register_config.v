`timescale 1ns / 1ps

module dma_register_config(
    input wire          clk,
    input wire          reset_n,
    
    input wire          wr_en,
    input wire [11:0]   wr_offset,
    input wire [31:0]   wr_data,
    input wire [11:0]   rd_offset,
    output reg [31:0]   rd_data,
    
    output reg [31:0]   src_addr,
    output reg [31:0]   dst_addr,
    output reg [15:0]   word_count,
    output reg          start,
    
    input wire          dma_busy,
    input wire          dma_done,
    input wire          dma_error
    );
    
    reg done_latched;
    reg error_latched;
    //写寄存器，以及保存dma的完整结果
    always@(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            src_addr <= 32'd0;
            dst_addr <= 32'd0;
            word_count <= 16'd0;
            start <= 1'b0;
            done_latched <= 1'b0;
            error_latched <= 1'b0;
        end else begin
            start <= 1'b0;
            
            if(dma_done) begin
                done_latched <= 1'b1;
                error_latched <= dma_error;
            end
            
            if(wr_en) begin
               case(wr_offset) 
                    12'h000:src_addr <= wr_data;
                    12'h004:dst_addr <= wr_data;
                    12'h008:word_count <= wr_data[15:0];
                    12'h00C: begin
                        if(wr_data[0] && !dma_busy && ! dma_done) begin
                            start <= 1'b1;
                            done_latched <= 1'b0;
                            error_latched <= 1'b0;
                        end
                    end
                    default: begin
                    end

               endcase 
            end
        end
    end
    
    
    //读寄存器，根据地址选择当前要读的值
    always@(*) begin
        case(rd_offset) 
            12'h000: rd_data = src_addr;
            12'h004: rd_data = dst_addr;
            12'h008: rd_data = {16'd0,word_count};
            12'h00C: rd_data = 32'd0;
            12'h010: rd_data = {29'd0,error_latched,done_latched,dma_busy};
            
            default: rd_data = 32'd0;
        endcase
    end
endmodule




























