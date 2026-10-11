`timescale 1ns / 1ps

//同步SRAM内核
module simple_sram_core #(
    parameter ADDR_WIDTH = 8
)(
    input   wire                     clk,
    input   wire                     enable,
    input   wire [3:0]               write_strobe,
    input   wire [ADDR_WIDTH-1:0]    word_address,
    input   wire [31:0]              write_data,
    output  reg  [31:0]              read_data 
);
    localparam WORD_COUNT = (1 << ADDR_WIDTH);
    
    reg [31:0] memory [0:WORD_COUNT-1];  
    
    always@ (posedge clk) begin
        if(enable) begin
           //根据write_strobe逐字节写入
           if(write_strobe[0])
               memory[word_address][7:0]<=
                         write_data[7:0];
               
           if(write_strobe[1])
               memory[word_address][15:8]<=
                         write_data[15:8];

           if(write_strobe[2])
               memory[word_address][23:16]<=
                         write_data[23:16];

           if(write_strobe[3])
               memory[word_address][31:24]<=
                         write_data[31:24];                       
           
           //同步读取整个32位word
           read_data <= memory[word_address];                             
        end
    end
    


endmodule





























































