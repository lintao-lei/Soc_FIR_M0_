`timescale 1ns / 1ps

module read_arbiter(
    input wire               clk,
    input wire               reset_n,
    // from cpu
    input wire               cpu_arvalid,
    input wire [31:0]        cpu_araddr,
    input wire [7:0]         cpu_arlen,
    input wire [2:0]         cpu_arsize,
    input wire [1:0]         cpu_arburst,
    output wire              cpu_arready,
    
    output wire [31:0]       cpu_rdata,
    output wire [1:0]        cpu_rresp,  //响应信息
    output wire              cpu_rlast, //是否是最后一个数据
    output wire              cpu_rvalid,
    input wire               cpu_rready,
    // from dma
    input wire               dma_arvalid,
    input wire [31:0]        dma_araddr,
    input wire [7:0]         dma_arlen,
    input wire [2:0]         dma_arsize,
    input wire [1:0]         dma_arburst,
    output wire              dma_arready,
    
    output wire [31:0]       dma_rdata,
    output wire [1:0]        dma_rresp,  //响应信息
    output wire              dma_rlast, //是否是最后一个数据
    output wire              dma_rvalid,
    input wire               dma_rready,
    //下游交互接口
    output wire              m_arvalid,
    output wire [31:0]       m_araddr,
    output wire [7:0]        m_arlen,
    output wire [2:0]        m_arsize,
    output wire [1:0]        m_arburst,
    input wire               m_arready,
    
    input wire [31:0]        m_rdata,
    input wire [1:0]         m_rresp,
    input wire               m_rlast,
    input wire               m_rvalid,
    output wire              m_rready
                              
    );
    
    localparam [1:0] ST_IDLE = 2'b00;
    localparam [1:0] ST_SEND_AR = 2'b01;
    localparam [1:0] ST_WAIT_R = 2'b10;
    
    reg [1:0]   state;
    reg owner_dma;
    reg [31:0] araddr_reg;
    reg [7:0]  arlen_reg;
    reg [2:0]  arsize_reg;
    reg [1:0]  arburst_reg;
    
    assign cpu_arready = reset_n && (state == ST_IDLE);
    assign dma_arready = reset_n && (state == ST_IDLE) && !cpu_arvalid;
    wire cpu_ar_handshake = cpu_arvalid && cpu_arready;
    wire dma_ar_handshake = dma_arvalid && dma_arready;
    
    assign m_araddr = araddr_reg;
    assign m_arlen = arlen_reg;
    assign m_arsize = arsize_reg;
    assign m_arburst = arburst_reg;
    assign m_arvalid = reset_n && (state == ST_SEND_AR);
    wire m_ar_handshake = m_arvalid && m_arready;
    
    assign cpu_rvalid = reset_n && (state == ST_WAIT_R) && !owner_dma && m_rvalid;
    assign dma_rvalid = reset_n && (state == ST_WAIT_R) && owner_dma && m_rvalid;
    assign m_rready  = reset_n && (state == ST_WAIT_R) && (owner_dma ? dma_rready : cpu_rready);
    
    assign cpu_rdata = cpu_rvalid ? m_rdata : 32'd0;
    assign cpu_rresp = cpu_rvalid ? m_rresp : 2'b00;
    assign cpu_rlast = cpu_rvalid ? m_rlast : 1'b0;
    assign dma_rdata = dma_rvalid ? m_rdata : 32'd0;
    assign dma_rresp = dma_rvalid ? m_rresp : 2'b00;
    assign dma_rlast = dma_rvalid ? m_rlast : 1'b0;         
    wire last_r_handshake = m_rvalid && m_rready && m_rlast;
    
    always@(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            state <= ST_IDLE;
            owner_dma <= 1'b0;
            araddr_reg <= 32'd0;
            arlen_reg <= 8'd0;
            arsize_reg <= 3'd0;
            arburst_reg <= 2'b00;
        end else begin
            case(state)
                ST_IDLE:begin
                    if(cpu_ar_handshake) begin
                        owner_dma <= 1'b0;
                        araddr_reg <= cpu_araddr;
                        arlen_reg <= cpu_arlen;
                        arsize_reg <= cpu_arsize;
                        arburst_reg <= cpu_arburst;
                        state <= ST_SEND_AR;
                    end else if(dma_ar_handshake) begin
                        owner_dma <= 1'b1;
                        araddr_reg <= dma_araddr;
                        arlen_reg <= dma_arlen;
                        arsize_reg <= dma_arsize;
                        arburst_reg <= dma_arburst;
                        state <= ST_SEND_AR;
                    end
                end 
                
                ST_SEND_AR: begin
                    if(m_ar_handshake) begin
                        state <= ST_WAIT_R;
                    end
                end 
                
                ST_WAIT_R: begin
                    if(last_r_handshake) begin
                        state <= ST_IDLE;
                    end
                end
                
                default: begin
                    state <= ST_IDLE;
                end  
               
            endcase
        end
    end 
endmodule

