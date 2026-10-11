`timescale 1ns / 1ps

module write_arbiter(
     input wire             clk,
     input wire             reset_n,
     //from cpu
     input wire             cpu_awvalid,
     output wire            cpu_awready,
     input wire [31:0]      cpu_awaddr,
     input wire [7:0]       cpu_awlen,
     input wire [2:0]       cpu_awsize,
     input wire [1:0]       cpu_awburst,
     
     input wire             cpu_wvalid,
     output wire            cpu_wready,
     input wire [31:0]      cpu_wdata,
     input wire [3:0]       cpu_wstrb,
     input wire             cpu_wlast,
     
     input wire             cpu_bready,
     output wire            cpu_bvalid,
     output wire [1:0]      cpu_bresp,
     
     //from dma
     input wire             dma_awvalid,
     output wire            dma_awready,
     input wire [31:0]      dma_awaddr,
     input wire [7:0]       dma_awlen,
     input wire [2:0]       dma_awsize,
     input wire [1:0]       dma_awburst,
     
     input wire             dma_wvalid,
     output wire            dma_wready,
     input wire [31:0]      dma_wdata,
     input wire [3:0]       dma_wstrb,
     input wire             dma_wlast,
     
     input wire             dma_bready,
     output wire            dma_bvalid,
     output wire [1:0]      dma_bresp,
     //给下游的
     output wire             m_awvalid,
     input wire              m_awready,
     output wire [31:0]      m_awaddr,
     output wire [7:0]       m_awlen,
     output wire [2:0]       m_awsize,
     output wire [1:0]       m_awburst,
     
     output wire             m_wvalid,
     input wire              m_wready,
     output wire [31:0]      m_wdata,
     output wire [3:0]       m_wstrb,
     output wire             m_wlast,
     
     output wire             m_bready,
     input wire              m_bvalid,
     input wire [1:0]        m_bresp
    );
    
    localparam [1:0] ST_IDLE = 2'b00;
    localparam [1:0] ST_ACTIVE = 2'b01;
    localparam [1:0] ST_WAIT_B = 2'b10;
    
    reg [1:0] state;
    reg owner_dma;
    reg aw_done;
    reg w_done;
    reg [31:0] awaddr_reg;
    reg [7:0]  awlen_reg;
    reg [2:0]  awsize_reg;
    reg [1:0]  awburst_reg;
    
    assign cpu_awready = reset_n && (state == ST_IDLE);
    assign dma_awready = reset_n && (state == ST_IDLE) && !cpu_awvalid;
    wire cpu_aw_handshake = cpu_awvalid && cpu_awready;
    wire dma_aw_handshake = dma_awvalid && dma_awready;
    
    assign m_awaddr = awaddr_reg;
    assign m_awlen = awlen_reg;
    assign m_awsize = awsize_reg;
    assign m_awburst = awburst_reg; 
    assign m_awvalid = reset_n && (state == ST_ACTIVE) && !aw_done;
    wire m_aw_handshake = m_awvalid && m_awready;
    
    assign m_wdata  = owner_dma ? dma_wdata  : cpu_wdata;
    assign m_wstrb  = owner_dma ? dma_wstrb  : cpu_wstrb;
    assign m_wlast  = owner_dma ? dma_wlast  : cpu_wlast;
    assign m_wvalid = reset_n && (state == ST_ACTIVE) && !w_done && (owner_dma ? dma_wvalid : cpu_wvalid);
    assign cpu_wready = reset_n && (state == ST_ACTIVE) && !w_done && !owner_dma && m_wready;
    assign dma_wready = reset_n && (state == ST_ACTIVE) && !w_done && owner_dma && m_wready;
    wire last_w_handshake = m_wvalid && m_wready && m_wlast;
    
    assign cpu_bvalid = reset_n && (state == ST_WAIT_B) && !owner_dma && m_bvalid;
    assign dma_bvalid = reset_n && (state == ST_WAIT_B) && owner_dma && m_bvalid;
    assign cpu_bresp = !owner_dma ? m_bresp : 2'b00;
    assign dma_bresp = owner_dma ? m_bresp : 2'b00;
    assign m_bready = reset_n && (state == ST_WAIT_B) && (!owner_dma ? cpu_bready : dma_bready);
    wire m_b_handshake = m_bvalid && m_bready;
    
    always@(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            state <= ST_IDLE;
            owner_dma <= 1'b0;
            aw_done <= 1'b0;
            w_done <= 1'b0;
            awaddr_reg <= 32'd0;
            awlen_reg <= 8'd0;
            awsize_reg <= 3'd0;
            awburst_reg <= 2'd0;
        end else begin
            case (state)
                ST_IDLE:begin
                    if(cpu_aw_handshake) begin
                        owner_dma <= 1'b0;
                        aw_done     <= 1'b0;
                        w_done      <= 1'b0;
                        awaddr_reg  <= cpu_awaddr;
                        awlen_reg   <= cpu_awlen;
                        awsize_reg  <= cpu_awsize;
                        awburst_reg <= cpu_awburst;
                        state       <= ST_ACTIVE;
                    end else if(dma_aw_handshake) begin
                        owner_dma   <= 1'b1;
                        aw_done     <= 1'b0;
                        w_done      <= 1'b0;
                        awaddr_reg  <= dma_awaddr;
                        awlen_reg   <= dma_awlen;
                        awsize_reg  <= dma_awsize;
                        awburst_reg <= dma_awburst;
                        state       <= ST_ACTIVE;
                    end
                end
              
                ST_ACTIVE:begin
                    if(m_aw_handshake)  aw_done <= 1'b1;
                    if(last_w_handshake) w_done <= 1'b1;
                    if((m_aw_handshake || aw_done) && 
                       (last_w_handshake || w_done)) 
                       state <= ST_WAIT_B;
                end
                
                ST_WAIT_B:begin
                    if(m_b_handshake) state <= ST_IDLE;
                end
                
                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end 
endmodule
