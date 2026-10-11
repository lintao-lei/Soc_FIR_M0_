`timescale 1ns / 1ps


module dma_carry(
    input wire              clk,
    input wire              reset_n,
    
    input wire              start,
    input wire [31:0]       src_addr,
    input wire [31:0]       dst_addr,
    input wire [15:0]       word_count,
    input wire              allow_fixed_burst,
    // 1锛氭瘡瀹屾垚涓?娈典紶杈撳悗鍦板潃閫掑锛?0锛氬缁堣闂悓涓?涓湴鍧?銆?
    input wire              src_increment,
    input wire              dst_increment,
    output wire             busy,
    output wire             done,
    output reg              error,
    
    //AXI read address (AR) :DMA发起读请求?
    output wire [31:0]      m_araddr,
    output wire [7:0]       m_arlen,
    output wire [2:0]       m_arsize,
    output wire [1:0]       m_arburst,
    output wire             m_arvalid,
    input wire              m_arready,
    
    //AXI read data (R) : DMA接收读结果?
    input wire [31:0]       m_rdata,
    input wire [1:0]        m_rresp,
    input wire              m_rlast,
    input wire              m_rvalid,
    output wire             m_rready,
    
    //AXI write address (AW): DMA发起写请求?
    output wire [31:0]      m_awaddr,
    output wire [7:0]       m_awlen,
    output wire [2:0]       m_awsize,
    output wire [1:0]       m_awburst,
    output wire             m_awvalid,
    input wire              m_awready,
    
    //AXI write data (W) : DMA发送写的内容?
    output wire [31:0]      m_wdata,
    output wire [3:0]       m_wstrb,
    output wire             m_wlast,
    output wire             m_wvalid,
    input wire              m_wready,
    
    //AXI write response (B): 确认写入是否成功
    input wire [1:0]        m_bresp,
    input wire              m_bvalid,
    output wire             m_bready
    );
    
    localparam [2:0] ST_IDLE        = 3'd0;
    localparam [2:0] ST_PREP_BURST  = 3'd1;
    localparam [2:0] ST_SEND_AR     = 3'd2;
    localparam [2:0] ST_WAIT_R      = 3'd3;
    localparam [2:0] ST_SEND_AW     = 3'd4;
    localparam [2:0] ST_SEND_W      = 3'd5;
    localparam [2:0] ST_WAIT_B      = 3'd6;
    localparam [2:0] ST_DONE        = 3'd7;
    
    localparam [1:0] AXI_BURST_FIXED = 2'b00;
    localparam [1:0] AXI_BURST_INCR  = 2'b01;
    
    localparam [1:0] RESP_OKAY      = 2'd0;
    
    reg [2:0] state;
    reg [31:0] src_addr_reg;
    reg [31:0] dst_addr_reg; 
    reg allow_fixed_burst_reg;
    reg        src_increment_reg;
    reg        dst_increment_reg;
    reg [15:0] remaining_words; //还剩多少个word未完成写响应
    
    reg [31:0] buffer [0:15];
    reg [4:0]  burst_words;
    reg [4:0]  write_index;
    reg [4:0]  read_index;
    
    wire [12:0] src_bytes_to_boundry = 13'd4096 - {1'b0,src_addr_reg[11:0]};
    wire [12:0] dst_bytes_to_boundry = 13'd4096 - {1'b0,dst_addr_reg[11:0]};
    
    wire [10:0] src_words_to_boundry = src_bytes_to_boundry[12:2];
    wire [10:0] dst_words_to_boundry = dst_bytes_to_boundry[12:2];
    
    // 两侧都递增时，天然支持INCR Burst。
    // 只要有一侧固定，必须由软件明确允许FIXED Burst。
    // 源端和目标端分别决定是否使用多拍事务：
    //   * 地址递增的 SRAM 端使用 INCR Burst；
    //   * 明确允许固定 Burst 的 FIR FIFO 端使用 FIXED Burst；
    //   * 地址固定但不允许固定 Burst 的 APB/UART 端使用重复单拍。
    // 必须使用任务开始时锁存的配置，不能继续查看可能变化的输入端口。
    wire read_is_burst  = src_increment_reg || allow_fixed_burst_reg;
    wire write_is_burst = dst_increment_reg || allow_fixed_burst_reg;
    
    wire [15:0] limit_16 =
        (remaining_words > 16'd16) ? 16'd16 : remaining_words;

    wire [15:0] limit_src =
        src_increment_reg &&
        (limit_16 > {5'd0, src_words_to_boundry})
            ? {5'd0, src_words_to_boundry}
            : limit_16;

    wire [15:0] limit_dst =
        dst_increment_reg &&
        (limit_src > {5'd0, dst_words_to_boundry})
            ? {5'd0, dst_words_to_boundry}
            : limit_src;
            
    
    assign m_araddr  = src_addr_reg;
    assign m_arlen   = (read_is_burst && (burst_words != 5'd0))
                     ? ({3'd0, burst_words} - 8'd1) : 8'd0;
    assign m_arsize  = 3'b010;
    assign m_arburst =
    (!src_increment_reg && allow_fixed_burst_reg)
        ? AXI_BURST_FIXED
        : AXI_BURST_INCR;
    assign m_arvalid = reset_n && (state == ST_SEND_AR);
    assign m_rready  = reset_n && (state == ST_WAIT_R);

    assign m_awaddr  = dst_addr_reg;
    assign m_awlen   = (write_is_burst && (burst_words != 5'd0))
                     ? ({3'd0, burst_words} - 8'd1) : 8'd0;
    assign m_awsize  = 3'b010;
    assign m_awburst =
    (!dst_increment_reg && allow_fixed_burst_reg)
        ? AXI_BURST_FIXED
        : AXI_BURST_INCR;
    assign m_awvalid = reset_n && (state == ST_SEND_AW);
    assign m_wdata   = buffer[write_index];
    assign m_wstrb   = 4'b1111;
    assign m_wlast   = write_is_burst
        ? (write_index == burst_words - 5'd1)
        : 1'b1;
    assign m_wvalid  = reset_n && (state == ST_SEND_W);
    assign m_bready  = reset_n && (state == ST_WAIT_B);
    
    assign busy = reset_n && (state != ST_IDLE) && (state != ST_DONE);
    assign done = reset_n && (state == ST_DONE);
    wire expected_rlast = read_is_burst
                        ? (read_index == burst_words - 5'd1)
                        : 1'b1;
    
    integer i;
    always@(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            state <= ST_IDLE;
            src_addr_reg <= 32'd0;
            dst_addr_reg <= 32'd0;
            src_increment_reg <= 1'b0;
            dst_increment_reg <= 1'b0;
            allow_fixed_burst_reg <= 1'b0;
            error<= 1'b0;
            remaining_words <= 16'd0;
            burst_words <= 5'd0;
            write_index <= 5'd0;
            read_index <= 5'd0;
            for(i=0;i<16;i=i+1) begin
                buffer[i] <= 32'd0;
            end
        end else begin
            case(state)
                ST_IDLE: begin
                    if(start) begin
                        src_addr_reg <= src_addr;
                        dst_addr_reg <= dst_addr;
                        src_increment_reg <= src_increment;
                        dst_increment_reg <= dst_increment;
                        allow_fixed_burst_reg <= allow_fixed_burst;
                        remaining_words <= word_count;
                        error <= 1'b0;
                        if ((src_addr[1:0] != 2'b00) ||
                            (dst_addr[1:0] != 2'b00) ||
                             word_count == 16'd0) begin
                            error<= 1'b1;
                            state <= ST_DONE;
                        end else begin
                            state <= ST_PREP_BURST;
                        end
                    end
                end
                
                ST_PREP_BURST: begin
                    write_index <= 5'd0;
                    read_index  <= 5'd0;
                    burst_words <= limit_dst[4:0];
                    state <= ST_SEND_AR;
                end
                
                ST_SEND_AR:begin
                    if(m_arvalid && m_arready)
                        state <= ST_WAIT_R;
                        
                end
                
                ST_WAIT_R: begin
                    if(m_rvalid && m_rready) begin
                        if(m_rlast != expected_rlast) begin
                            // RLAST位置错误，当前AXI事务已经违反协议。
                            error <= 1'b1;
                            state <= ST_DONE;
                        end else begin
                            // RRESP出错时仍继续接收到本次Burst的最后一拍，
                            // 防止在Burst中途撤销RREADY而锁住下游从设备。
                            if(m_rresp != RESP_OKAY)
                                error <= 1'b1;

                            if((m_rresp == RESP_OKAY) && !error)
                                buffer[read_index] <= m_rdata;

                            if(read_index == burst_words - 5'd1) begin
                                if((m_rresp != RESP_OKAY) || error) begin
                                    error <= 1'b1;
                                    state <= ST_DONE;
                                end else begin
                                    write_index <= 5'd0;
                                    state <= ST_SEND_AW;
                                end
                            end else begin
                                read_index <= read_index + 5'd1;

                                // 单拍外设每收一个R响应，都需要重新发送AR；
                                // Burst源端则保持在WAIT_R接收下一拍。
                                if(!read_is_burst)
                                    state <= ST_SEND_AR;
                            end
                        end
                    end
                end
                
                ST_SEND_AW : begin
                    if(m_awvalid && m_awready)
                        state <= ST_SEND_W;
                end
                
                ST_SEND_W: begin
                    if(m_wvalid && m_wready) begin
                        if(m_wlast) begin
                            state <= ST_WAIT_B;
                        end else begin
                            write_index <= write_index + 5'd1;
                        end
                    end
                end
                
                ST_WAIT_B:begin
                    if(m_bvalid && m_bready) begin
                        if(m_bresp != RESP_OKAY) begin
                            error <= 1'b1;
                            state <= ST_DONE;
                        end else if(!write_is_burst && 
                                    write_index != burst_words - 5'd1) begin
                            // 单拍外设每个word都有独立的AW/W/B事务。
                            write_index <= write_index + 5'd1;
                            state <= ST_SEND_AW;
                        end else if(remaining_words ==
                                    {11'd0, burst_words}) begin
                            remaining_words <= 16'd0;
                            state <= ST_DONE;
                        end else begin
                            remaining_words <= remaining_words - {11'd0, burst_words};

                            if(src_increment_reg)
                                src_addr_reg <= src_addr_reg +
                                                ({27'd0, burst_words} << 2);

                            if(dst_increment_reg)
                                dst_addr_reg <= dst_addr_reg +
                                                ({27'd0, burst_words} << 2);

                            state <= ST_PREP_BURST;
                        end
                    end
                end
                
                ST_DONE : begin
                    state <= ST_IDLE;
                end
                
                default : begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end
  
    
endmodule










