`timescale 1ns / 1ps


module dma6_register_file(
    input wire         clk,
    input wire         reset_n,
    
    // 来自axi_dma_reg_slave的本地寄存器接口
    input  wire        wr_en,
    input  wire [11:0] wr_offset,
    input  wire [31:0] wr_data,
    input  wire [11:0] rd_offset,
    output reg  [31:0] rd_data,
    
    // 让调度器快速知道哪些通道正在等待
    output wire [5:0]  channel_pending,
    output wire [5:0]  channel_busy,
    output wire [5:0]  channel_done,
    output wire [5:0]  channel_error,
    
    // 调度器选择一个通道读取配置
    input  wire [2:0]  scheduler_channel,
    output wire [31:0] scheduler_src_addr,
    output wire [31:0] scheduler_dst_addr,
    output wire [15:0] scheduler_word_count,
    output wire        scheduler_irq_enable,
    output wire        scheduler_src_increment,
    output wire        scheduler_dst_increment,
    output wire   scheduler_fixed_burst_enable,
    
    // 调度器接管当前通道
    input  wire        scheduler_claim,

    // 搬运引擎完成当前通道
    input  wire        scheduler_complete,
    input  wire        scheduler_error,
    output wire        scheduler_enable,
    
    // 六路通道中断
    output wire [5:0]  irq
    );
    
    localparam [11:0] REG_GLOBAL_CONTROL = 12'h180;
    localparam [11:0] REG_PENDING_MASK   = 12'h184;
    localparam [11:0] REG_BUSY_MASK      = 12'h188;
    localparam [11:0] REG_DONE_MASK      = 12'h18C;
    localparam [11:0] REG_ERROR_MASK     = 12'h190;
    
    localparam integer CHANNEL_COUNT = 6;
    
    localparam integer CTRL_START_BIT = 0;
    localparam integer CTRL_IRQ_EN_BIT = 1;
    localparam integer CTRL_SRC_INC_BIT = 2;
    localparam integer CTRL_DST_INC_BIT = 3;
    localparam integer CTRL_FIXED_BURST_BIT = 4;
    
    localparam integer STATUS_PENDING_BIT = 0;
    localparam integer STATUS_BUSY_BIT = 1;
    localparam integer STATUS_DONE_BIT = 2;
    localparam integer STATUS_ERROR_BIT = 3;
    
    localparam [5:0] REG_SRC_ADDR = 6'h00;
    localparam [5:0] REG_DST_ADDR = 6'h04;
    localparam [5:0] REG_WORD_COUNT = 6'h08;
    localparam [5:0] REG_CONTROL = 6'h0C;
    localparam [5:0] REG_STATUS = 6'h10;
    localparam [5:0] REG_REMAINING = 6'h14;
    localparam [5:0] REG_CURRENT_SRC = 6'h18;
    localparam [5:0] REG_CURRENT_DST = 6'h1C;

    reg [31:0] src_addr_reg      [0:CHANNEL_COUNT-1];
    reg [31:0] dst_addr_reg      [0:CHANNEL_COUNT-1];
    reg [15:0] word_count_reg    [0:CHANNEL_COUNT-1];
    
    reg        irq_enable_reg    [0:CHANNEL_COUNT-1];
    reg        src_increment_reg [0:CHANNEL_COUNT-1];
    reg        dst_increment_reg [0:CHANNEL_COUNT-1];
    
    reg [31:0] current_src_reg   [0:CHANNEL_COUNT-1];
    reg [31:0] current_dst_reg   [0:CHANNEL_COUNT-1];
    reg [15:0] remaining_reg     [0:CHANNEL_COUNT-1];
    reg fixed_burst_enable_reg   [0:CHANNEL_COUNT-1];
    
    reg [5:0] pending_reg;
    reg [5:0] busy_reg;
    reg [5:0] done_reg;
    reg [5:0] error_reg;
    reg scheduler_enable_reg;
    
    wire [2:0] write_channel = wr_offset[8:6];
    wire [5:0] write_register_offset = wr_offset[5:0];    
    wire [2:0] read_channel = rd_offset[8:6];
    wire [5:0] read_register_offset  = rd_offset[5:0];
    
    //地址合法性检验    
    wire write_channel_valid = ((wr_offset[11:9]== 3'b000)&&
                                  (write_channel < 3'd6)&&
                                  (wr_offset[1:0]==2'b00));
                                  
    wire read_channel_valid = ((rd_offset[11:9]== 3'b000)&&
                                  (read_channel < 3'd6)&&
                                  (rd_offset[1:0]==2'b00));                              
    
    wire scheduler_channel_valid = (scheduler_channel<3'd6);
    //输出給调度器的配置
    wire write_channel_locked = write_channel_valid ? (pending_reg[write_channel]|| busy_reg[write_channel]) : 1'b1;
    wire write_global_control =wr_en && (wr_offset == REG_GLOBAL_CONTROL);
    assign channel_pending = pending_reg;
    assign channel_busy = busy_reg;
    assign channel_done = done_reg;
    assign channel_error = error_reg;
    
    assign scheduler_src_addr =scheduler_channel_valid ? current_src_reg[scheduler_channel] : 32'd0;
    assign scheduler_dst_addr =scheduler_channel_valid ? current_dst_reg[scheduler_channel] : 32'd0;
    assign scheduler_word_count =scheduler_channel_valid ? remaining_reg[scheduler_channel] : 16'd0;
    assign scheduler_irq_enable = scheduler_channel_valid ? irq_enable_reg[scheduler_channel]: 1'b0;
    assign scheduler_src_increment = scheduler_channel_valid ? src_increment_reg[scheduler_channel]: 1'b0;
    assign scheduler_dst_increment = scheduler_channel_valid ? dst_increment_reg[scheduler_channel]: 1'b0;
    assign scheduler_fixed_burst_enable = scheduler_channel_valid ? fixed_burst_enable_reg[scheduler_channel]: 1'b0;
    assign scheduler_enable = scheduler_enable_reg;
   
    genvar channel_index; 
    generate
        for(channel_index = 0;
            channel_index < CHANNEL_COUNT;
            channel_index = channel_index + 1)begin : GEN_IRQ
            assign irq[channel_index] = irq_enable_reg[channel_index]&&
                                        (done_reg[channel_index] || error_reg[channel_index]);
            end
    endgenerate
    
    integer i;
    always@(posedge clk or negedge reset_n) begin
        if(!reset_n) begin 
            pending_reg <= 6'd0;
            busy_reg    <= 6'd0;
            done_reg    <= 6'd0;
            error_reg   <= 6'd0;
            scheduler_enable_reg <= 1'b1;
            for (i = 0; i < CHANNEL_COUNT; i = i + 1) begin
                src_addr_reg[i]      <= 32'd0;
                dst_addr_reg[i]      <= 32'd0;
                word_count_reg[i]    <= 16'd0;
                irq_enable_reg[i]    <= 1'b0;
                src_increment_reg[i] <= 1'b0;
                dst_increment_reg[i] <= 1'b0;   
                current_src_reg[i]   <= 32'd0;
                current_dst_reg[i]   <= 32'd0;
                remaining_reg[i]     <= 16'd0;
                fixed_burst_enable_reg[i] <= 1'b0;
            end
        end else begin   
        if (write_global_control)
            scheduler_enable_reg <= wr_data[0];
            
            if(wr_en&&write_channel_valid) begin
                case(write_register_offset)
                    REG_SRC_ADDR: begin
                        if(!write_channel_locked)
                            src_addr_reg[write_channel] <= wr_data;
                    end
                    
                    REG_DST_ADDR:begin
                        if(!write_channel_locked)
                            dst_addr_reg[write_channel] <= wr_data;
                    end
                    
                    REG_WORD_COUNT:begin
                        if(!write_channel_locked)
                            word_count_reg[write_channel] <= wr_data[15:0];
                    end
                    
                    REG_CONTROL:begin
                        if(!write_channel_locked) begin
                            irq_enable_reg[write_channel] <= wr_data[CTRL_IRQ_EN_BIT];
                            src_increment_reg[write_channel] <= wr_data[CTRL_SRC_INC_BIT];
                            dst_increment_reg[write_channel] <= wr_data[CTRL_DST_INC_BIT];
                            fixed_burst_enable_reg[write_channel]<= wr_data[CTRL_FIXED_BURST_BIT];
                            
                            if(wr_data[CTRL_START_BIT])begin
                                current_src_reg[write_channel] <= src_addr_reg[write_channel];
                                current_dst_reg[write_channel] <= dst_addr_reg[write_channel];
                                remaining_reg[write_channel] <= word_count_reg[write_channel];
                                
                                done_reg[write_channel] <= 1'b0;
                                error_reg[write_channel] <= 1'b0;
                                busy_reg[write_channel] <= 1'b0;
                                
                                if((src_addr_reg[write_channel][1:0] == 2'b00)&&
                                   (dst_addr_reg[write_channel][1:0] == 2'b00)&&
                                   (word_count_reg[write_channel]) != 16'd0) begin
                                        pending_reg[write_channel] <= 1'b1;
                                end else begin
                                        pending_reg[write_channel] <= 1'b0;
                                        error_reg[write_channel] <= 1'b1;
                                end
                            end
                        end
                    end
                    
                    REG_STATUS:begin
                        if(wr_data[STATUS_DONE_BIT])
                            done_reg[write_channel] <= 1'b0;
                        if(wr_data[STATUS_ERROR_BIT])
                            error_reg[write_channel]<= 1'b0;
                    end
                    
                    default:begin
                    end 
                endcase
            end 
          
            // -------------------------------------------------------------
            // 调度器事件写在本时序块的后面，因此当同一个时钟周期内
            // CPU 写寄存器和调度器事件发生冲突时，调度器事件优先。
            // -------------------------------------------------------------  
            if(scheduler_claim && scheduler_channel_valid &&
               pending_reg[scheduler_channel]) begin
                  pending_reg[scheduler_channel] <= 1'b0;
                  busy_reg[scheduler_channel] <= 1'b1;
                  done_reg[scheduler_channel] <= 1'b0;
                  error_reg[scheduler_channel] <= 1'b0; 
            end
               
            if(scheduler_complete && scheduler_channel_valid&&
               busy_reg[scheduler_channel])begin
                pending_reg[scheduler_channel] <= 1'b0;
                busy_reg[scheduler_channel] <= 1'b0;
                
                if(scheduler_error) begin
                    done_reg[scheduler_channel] <= 1'b0;
                    error_reg[scheduler_channel] <= 1'b1;
                end else begin
                    done_reg[scheduler_channel] <= 1'b1;
                    error_reg[scheduler_channel] <= 1'b0;
                    remaining_reg[scheduler_channel] <= 16'd0;
                end
            end   
        end
    end
    
    // ---------------------------------------------------------------------
    // CPU 寄存器读取采用组合逻辑。
    // 非法通道、未按 4 字节对齐的地址以及保留地址都返回 0。
    // ---------------------------------------------------------------------
    always@(*)begin
        rd_data = 32'd0;
        
        if (rd_offset == REG_GLOBAL_CONTROL) begin
             rd_data = {31'd0, scheduler_enable_reg};

        end else if (rd_offset == REG_PENDING_MASK) begin
             rd_data = {26'd0, pending_reg};

        end else if (rd_offset == REG_BUSY_MASK) begin
             rd_data = {26'd0, busy_reg};

        end else if (rd_offset == REG_DONE_MASK) begin
             rd_data = {26'd0, done_reg};

        end else if (rd_offset == REG_ERROR_MASK) begin
             rd_data = {26'd0, error_reg};
        
       end else if(read_channel_valid) begin
            case(read_register_offset)
                REG_SRC_ADDR:
                    rd_data = src_addr_reg[read_channel];
                
                REG_DST_ADDR:
                    rd_data = dst_addr_reg[read_channel];
                  
                REG_WORD_COUNT: 
                    rd_data= {16'd0,word_count_reg[read_channel]};     
                
                REG_CONTROL:
                    rd_data = {
                        27'd0,
                        fixed_burst_enable_reg[read_channel],
                        dst_increment_reg[read_channel],
                        src_increment_reg[read_channel],
                        irq_enable_reg[read_channel],
                        1'b0
                    };
                    
               REG_STATUS:
                    rd_data= {
                        28'd0,
                        error_reg[read_channel],
                        done_reg[read_channel],
                        busy_reg[read_channel],
                        pending_reg[read_channel]  
                    };     
                
               REG_REMAINING:
                    rd_data = {16'd0,remaining_reg[read_channel]};
                    
               REG_CURRENT_SRC:
                    rd_data = current_src_reg[read_channel];
               
               REG_CURRENT_DST:
                    rd_data = current_dst_reg[read_channel];     
                        
               default:
                    rd_data = 32'd0;               
            endcase
        end
    end

endmodule










