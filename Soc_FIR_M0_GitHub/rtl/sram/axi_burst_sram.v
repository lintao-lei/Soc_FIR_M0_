`timescale 1ns/1ps

module axi_burst_sram#(
    parameter integer SRAM_ADDR_WIDTH = 8
)(
    input wire                  clk,
    input wire                  reset_n,
    
    // AXI write-address channel
    input wire [31:0]           s_awaddr,
    input wire [7:0]            s_awlen,//burst的长度，他保存的是"数据拍总数-1"
    input wire [2:0]            s_awsize,//表示每一个数据拍有多少字节
    input wire [1:0]            s_awburst,//表示burst中每拍地址如何变化，00对应fixed类型，01对应incr,10对应wrap,11对应reserved
    input wire                  s_awvalid,
    output wire                 s_awready,
    
    // AXI write-data channel
    input wire [31:0]           s_wdata,
    input wire [3:0]            s_wstrb,
    input wire                  s_wlast,
    input wire                  s_wvalid,
    output wire                 s_wready,
    
    // AXI write-response channel    
    output wire [1:0]           s_bresp,
    output wire                 s_bvalid,
    input wire                  s_bready,
    
    // AXI read-address channel
    input wire [31:0]           s_araddr,
    input wire [7:0]            s_arlen,
    input wire [2:0]            s_arsize,
    input wire [1:0]            s_arburst,
    input wire                  s_arvalid,
    output wire                 s_arready,
 
    // AXI read-data channel
    output wire [31:0]          s_rdata,
    output wire [1:0]           s_rresp,
    output wire                 s_rlast,
    output wire                 s_rvalid,
    input wire                  s_rready 
);

    localparam [1:0] AXI_RESP_OKAY = 2'b00;  //写操作从设备回应时候，表示写操作正确进行了
    localparam [1:0] AXI_RESP_SLVERR = 2'b10; //写操作从设备回应时候，表示响应有效，但是从设备没有正确完成任务
    
    localparam [1:0] AXI_BURST_INCR = 2'b01;
    localparam [2:0] AXI_SIZE_4BYTE = 3'b010;
    
    //读操作的状态机
    localparam [1:0] RD_IDLE  = 2'b00;  //等待R请求
    localparam [1:0] RD_ISSUE = 2'b01;  //把当前地址同步交给SRAM
    localparam [1:0] RD_WAIT  = 2'b10;  //等待SRAM返回读出来的数据
    localparam [1:0] RD_SEND  = 2'b11;  //通过AXI R通道将读出来的数据返回给主机
   
      //合法性检查函数
    function burst_request_invalid;
        input [31:0] address;
        input [7:0]  length;
        input [2:0]  size;
        input [1:0]  burst;
        
        reg [12:0] beat_count;
        reg [12:0] byte_count;  
        reg [12:0] end_offset;
        
        begin
            beat_count = {5'd0,length} + 13'd1;
            byte_count = beat_count << 2;
            
            end_offset ={1'b0,address[11:0]} + byte_count ;
            burst_request_invalid = (address[1:0] != 2'b00)||
                                    (size != AXI_SIZE_4BYTE)||
                                    (burst != AXI_BURST_INCR)||
                                    (length > 8'd15) ||
                                    (end_offset > 13'd4096);                                 
        end
    endfunction
    
    //写操作通道
    reg                         write_active;
    reg [31:0]                  awaddr_reg;
    reg [7:0]                   awlen_reg;
    reg [2:0]                   awsize_reg;
    reg [1:0]                   awburst_reg;
    reg [7:0]                   write_beat_reg;
    wire                        write_expected_last;
            
    reg                         write_request_error_reg;  //aw请求本身非法
    reg                         write_error_reg;          //写过程中出现错误
    wire                        write_last_mismatch;
            
    reg [1:0] bresp_reg;
    reg       bvalid_reg;
    
    wire aw_handshake;  
    wire w_handshake;
    wire b_handshake;
        
    //读地址信号
    reg [1:0]                read_state;
    reg                      read_active;
    
    reg [31:0]               araddr_reg;
    reg [7:0]                arlen_reg;
    reg [2:0]                arsize_reg;
    reg [1:0]                arburst_reg;
    reg [7:0]                read_beat_reg;
    wire                     read_expected_last;
    
    reg [31:0]               rdata_reg;
    reg [1:0]                rresp_reg;
    reg                      rlast_reg;
    reg                      rvalid_reg; 
    
    reg                      read_error_reg;
    
    wire ar_handshake;
    wire r_handshake;
    //
    wire slave_idle;
    assign slave_idle = !write_active && !read_active && !bvalid_reg; 
    assign s_awready = reset_n && slave_idle;
    assign s_arready = reset_n && slave_idle && !s_awvalid; 
    assign s_wready = reset_n && write_active && !bvalid_reg;
    
    assign aw_handshake = s_awvalid && s_awready;      
    assign w_handshake = s_wvalid && s_wready; 
    assign b_handshake = s_bvalid && s_bready; 
    assign ar_handshake = s_arvalid && s_arready;
    assign r_handshake = s_rvalid && s_rready;
    
    assign read_expected_last = (read_beat_reg == arlen_reg);
    assign write_expected_last = (write_beat_reg == awlen_reg);
    assign write_last_mismatch = w_handshake && (s_wlast != write_expected_last);
    
    //SRAM端口定义及实例化
    wire write_sram_beat;
    wire issue_sram_read;
    wire                          sram_enable;
    wire [3:0]                    sram_write_strobe;
    wire [SRAM_ADDR_WIDTH-1:0]    sram_word_address;
    wire [31:0]                   sram_write_data;
    wire [31:0]                   sram_read_data;
    
    assign write_sram_beat = w_handshake && !write_request_error_reg; 
    assign issue_sram_read = read_active && (read_state == RD_ISSUE) && !read_error_reg;
    assign sram_enable = write_sram_beat || issue_sram_read;
    assign sram_write_strobe = write_sram_beat ? s_wstrb : 4'b0000;
    assign sram_word_address = write_sram_beat ? awaddr_reg[SRAM_ADDR_WIDTH+1:2] : araddr_reg[SRAM_ADDR_WIDTH+1:2];
    assign sram_write_data = s_wdata;
         
   simple_sram_core #(
        .ADDR_WIDTH(SRAM_ADDR_WIDTH)
   ) u_simple_sram_core (
        .clk          (clk),
        .enable       (sram_enable),
        .write_strobe (sram_write_strobe),
        .word_address (sram_word_address),
        .write_data   (sram_write_data),
        .read_data    (sram_read_data)
  );
                                      
    always@(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            write_active <= 1'b0;
        
            awaddr_reg <= 32'b0;
            awlen_reg <= 8'b0;
            awsize_reg <= 3'b0;
            awburst_reg <= 2'b00;
            
            write_beat_reg <= 8'd0;
            
            bresp_reg <=AXI_RESP_OKAY;
            bvalid_reg <= 1'b0; 
            
            write_error_reg <= 1'b0;
            write_request_error_reg <= 1'b0;
           
        end else begin
            if(b_handshake) begin
                bvalid_reg <= 1'b0;
            end
            
            if(aw_handshake) begin
                write_active <= 1'b1;
                
                awaddr_reg <= s_awaddr;
                awlen_reg <= s_awlen;
                awsize_reg <= s_awsize;
                awburst_reg <= s_awburst;
                
                write_beat_reg <= 8'd0;
                
                bresp_reg <= AXI_RESP_OKAY;
                
                 write_request_error_reg <= burst_request_invalid(
                                              s_awaddr,
                                              s_awlen,
                                              s_awsize,
                                              s_awburst);
                write_error_reg         <= burst_request_invalid(
                                              s_awaddr,
                                              s_awlen,
                                              s_awsize,
                                              s_awburst);
            end 
            
            if(w_handshake) begin
                if(write_last_mismatch) begin
                    write_error_reg <= 1'b1;
                end
                
                if(write_expected_last) begin
                    write_active <= 1'b0;
                    bvalid_reg <= 1'b1;

                    bresp_reg <=
                                 (write_error_reg || write_last_mismatch)
                                  ? AXI_RESP_SLVERR
                                  : AXI_RESP_OKAY;
                end else begin
                    write_beat_reg <= write_beat_reg + 8'd1;
                    awaddr_reg <= awaddr_reg + 32'd4;
                end
            end
            
        end
    end

    always@(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            read_active <= 1'b0;
            read_state <= RD_IDLE;
            
            araddr_reg <= 32'b0;
            arlen_reg <= 8'd0;
            arsize_reg <= 3'b000;
            arburst_reg <= 2'b00;
            
            read_beat_reg <= 8'd0;
      
            rdata_reg <= 32'd0;
            rresp_reg <= AXI_RESP_OKAY;
            rlast_reg <= 1'b0;
            rvalid_reg <= 1'b0;
            
            read_error_reg <= 1'b0;
        end else begin
            case(read_state) 
                RD_IDLE:begin
                    if(ar_handshake) begin
                        read_active <= 1'b1;
                        araddr_reg <= s_araddr;
                        arlen_reg <= s_arlen;
                        arsize_reg <= s_arsize;
                        arburst_reg <= s_arburst;
                        
                        read_beat_reg <= 8'd0;
                        read_error_reg <= burst_request_invalid(
                                          s_araddr,
                                          s_arlen,
                                          s_arsize,
                                          s_arburst);    
                                        
                        if(burst_request_invalid(
                                          s_araddr,
                                          s_arlen,
                                          s_arsize,
                                          s_arburst)) begin
                           rdata_reg <= 32'd0;
                           rresp_reg <= AXI_RESP_SLVERR;
                           rlast_reg <= (s_arlen == 8'd0);  
                           rvalid_reg <= 1'b1;
                           read_state <= RD_SEND;             
                        end else begin
                           rvalid_reg <= 1'b0;
                           read_state <= RD_ISSUE; 
                        end                                           
                    end
                end
                RD_ISSUE:begin
                    //后面会在这个阶段向同步SRAM发送读请求
                    
                    read_state <= RD_WAIT;
                end    
                RD_WAIT:begin
                    rdata_reg <= sram_read_data;
                    rresp_reg <= AXI_RESP_OKAY;
                    rlast_reg <= read_expected_last;                
                    rvalid_reg <= 1'b1;
                    read_state <= RD_SEND;
                end
                RD_SEND:begin
                    if(r_handshake) begin
                        if(read_expected_last) begin
                            rvalid_reg <= 1'b0;
                            rlast_reg <= 1'b0;
                            
                            read_active <= 1'b0;
                            read_state <= RD_IDLE;
                        end else begin                        
                            read_beat_reg <= read_beat_reg + 8'd1;  
                            araddr_reg <= araddr_reg + 32'd4;
                            
                            if(read_error_reg) begin
                                rdata_reg <= 32'd0;
                                rresp_reg <= AXI_RESP_SLVERR;
                                rlast_reg <= ((read_beat_reg + 8'd1) == arlen_reg);
                                rvalid_reg <= 1'b1;
                                read_state <= RD_SEND;
                            end else begin
                                rvalid_reg <= 1'b0;
                                read_state <= RD_ISSUE;
                            end
                        end
                    end
                end
                default:begin
                    read_active <= 1'b0;
                    read_state <= RD_IDLE;
                    
                    rvalid_reg <= 1'b0;
                    rlast_reg <= 1'b0;
                end
            endcase
        end
        
    end

    assign s_bvalid = bvalid_reg;
    assign s_bresp = bresp_reg;
    
    assign s_rdata  = rdata_reg;
    assign s_rresp  = rresp_reg;
    assign s_rlast  = rlast_reg;
    assign s_rvalid = rvalid_reg;

endmodule

