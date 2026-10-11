`timescale 1ns / 1ps


module ahb_to_axi_bridge(
    input wire          clk,
    input wire          reset_n,
    
    input wire[31:0]    haddr,
    input wire[2:0]     hburst,
    input wire          hmastlock,
    input wire[3:0]     hprot,
    input wire[2:0]     hsize,
    input wire[1:0]     htrans,
    input wire[31:0]    hwdata,
    input wire          hwrite,
    output wire [31:0]  hrdata,
    output wire         hready,
    output wire         hresp,
    
    output wire [31:0]  m_awaddr,
    output wire [7:0]   m_awlen,
    output wire [2:0]   m_awsize,
    output wire [1:0]   m_awburst,
    output wire         m_awvalid,
    input wire          m_awready,
    output wire [31:0]  m_wdata,
    output wire [3:0]   m_wstrb,
    output wire         m_wlast,
    output wire         m_wvalid,
    input wire          m_wready,
    input wire [1:0]    m_bresp,
    input wire          m_bvalid,
    output wire         m_bready,
    
    output wire [31:0]  m_araddr,
    output wire [7:0]   m_arlen,
    output wire [2:0]   m_arsize,
    output wire [1:0]   m_arburst,
    output wire         m_arvalid,
    input wire          m_arready,
    input wire [31:0]   m_rdata,
    input wire [1:0]    m_rresp,
    input wire          m_rlast,
    input wire          m_rvalid,
    output wire         m_rready
    );
    
    localparam [1:0]    HTRANS_NONSEQ        = 2'b10;
    localparam [2:0]    HBURST_SINGLE        = 3'b000;
    localparam [2:0]    HSIZE_WORD           = 3'b010;
    
    localparam [1:0]    AXI_RESP_OKAY        = 2'b00;

    localparam [2:0]    ST_IDLE              = 3'd0;
    localparam [2:0]    ST_AHB_WRITE_DATA    = 3'd1;
    localparam [2:0]    ST_AXI_WRITE         = 3'd2;
    localparam [2:0]    ST_WAIT_BRESP        = 3'd3;
    localparam [2:0]    ST_AXI_READ          = 3'd4;
    localparam [2:0]    ST_WAIT_RDATA        = 3'd5;
    localparam [2:0]    ST_AHB_ERROR_1       = 3'd6;
    localparam [2:0]    ST_AHB_COMPLETE      = 3'd7;
    
    reg [2:0]   state;
    
    // AHB address/control phase holding registers. HWDATA belongs to the
    // following data phase, so it is captured separately one cycle later.
    reg [31:0]  ahb_addr_reg;
    reg         ahb_write_reg;
    reg [2:0]   ahb_size_reg;
    reg         ahb_request_error_reg;
    reg [31:0]  ahb_wdata_reg;
    
    // AXI AW and W are independent channels. These flags remember which
    // channel has already completed its VALID/READY handshake.
    
    reg         aw_sent;
    reg         w_sent;
    
    reg [31:0]  hrdata_reg;
    reg         hresp_reg;
    
    wire        ahb_address_valid = htrans[1];
    
    // This first version accepts only an aligned, single, 32-bit transfer.
    
    wire ahb_request_unsupported = 
        (htrans != HTRANS_NONSEQ) ||
        (hburst != HBURST_SINGLE) ||
        (hsize  != HSIZE_WORD)    || 
        (haddr[1:0] != 2'b00);
        
    wire axi_aw_handshake = m_awvalid && m_awready;
    wire axi_w_handshake  = m_wvalid && m_wready;
    wire axi_b_handshake  = m_bvalid && m_bready;
    wire axi_ar_handshake = m_arvalid && m_arready;
    wire axi_r_handshake  = m_rvalid && m_rready;
    
    // --------------------------------------------------------------
    // AHB response interface
    // --------------------------------------------------------------
    assign hrdata = hrdata_reg;
    
    // HREADY is high while idle and for the final AHB response cycle. It is
    // low while the bridge captures write data or waits for AXI.
    assign hready = (state == ST_IDLE) || (state == ST_AHB_COMPLETE);
    
    // AHB-Lite ERROR uses two response cycles:
    //   ST_AHB_ERROR_1  : HRESP=1, HREADY=0
    //   ST_AHB_COMPLETE : HRESP=1, HREADY=1
    assign hresp = (state == ST_AHB_ERROR_1)   ? 1'b1 :
                   (state == ST_AHB_COMPLETE) ? hresp_reg :
                                                 1'b0;
                                                 
    // --------------------------------------------------------------
    // AXI single-beat output interface
    // --------------------------------------------------------------                                              
       
       assign m_awaddr    = ahb_addr_reg;
       assign m_awlen     = 8'd0;
       assign m_awsize    = HSIZE_WORD;
       assign m_awburst   = 2'b01;
       assign m_awvalid   = (state==ST_AXI_WRITE) && !aw_sent;
       
       assign m_wdata     = ahb_wdata_reg;
       assign m_wstrb     = 4'b1111;
       assign m_wlast     = 1'b1;
       assign m_wvalid    = (state == ST_AXI_WRITE) && !w_sent;
    
       assign m_bready    = (state == ST_WAIT_BRESP);
       
       assign m_araddr    = ahb_addr_reg;
       assign m_arlen     = 8'd0;
       assign m_arsize    = HSIZE_WORD;
       assign m_arburst   = 2'b01;
       assign m_arvalid   = (state == ST_AXI_READ);
       
       assign m_rready    = (state == ST_WAIT_RDATA);
       
    // --------------------------------------------------------------
    // Bridge state machine
    // -------------------------------------------------------------- 
    
    
    always@ (posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            state   <= ST_IDLE;
            ahb_addr_reg <= 32'b0;
            ahb_write_reg <= 1'b0;
            ahb_size_reg <= HSIZE_WORD;
            ahb_request_error_reg <= 1'b0;
            ahb_wdata_reg <= 32'h0;
            aw_sent <= 1'b0;
            w_sent <= 1'b0;
            hrdata_reg <= 32'b0;
            hresp_reg <= 1'b0;
        end else begin
            case(state) 
                ST_IDLE: begin
                    aw_sent <= 1'b0;
                    w_sent <= 1'b0;
                    
                    // The bridge is the only AHB slave in this shell, so no
                    // HSEL input is required. HTRANS[1] marks a valid address
                    // phase while HREADY is high in ST_IDLE.
                    if(ahb_address_valid ) begin
                        ahb_addr_reg          <= haddr;
                        ahb_write_reg         <= hwrite;
                        ahb_size_reg          <= hsize;
                        ahb_request_error_reg <= ahb_request_unsupported;
                        hresp_reg             <= 1'b0;
                        
                        if(hwrite) begin
                            // HWDATA is not valid for this transfer until the
                            // following AHB data phase.
                            state <= ST_AHB_WRITE_DATA;
                        end else if(ahb_request_unsupported) begin
                            hresp_reg <= 1'b1;
                            state     <= ST_AHB_ERROR_1;
                        end else begin
                            state <= ST_AXI_READ; 
                        end
                    end
                end
                
                ST_AHB_WRITE_DATA:begin
                    // Capture the write data one phase after its address.
                    // HREADY is low in this state, so the AHB master holds
                    // HWDATA stable while the bridge samples it. 
                    ahb_wdata_reg <= hwdata;
                    aw_sent <= 1'b0;
                    w_sent <= 1'b0;
                    
                    if(ahb_request_error_reg) begin
                        hresp_reg <= 1'b1;
                        state <= ST_AHB_ERROR_1;
                    end else begin
                        state <= ST_AXI_WRITE;
                    end
                end
                
                ST_AXI_WRITE : begin
                    if(axi_aw_handshake)
                       aw_sent <= 1'b1;
                    if(axi_w_handshake) 
                       w_sent <= 1'b1;
                          
                    // Include handshakes occurring on the current edge, so
                    // AW and W may complete in either order or together.
                    if((aw_sent || axi_aw_handshake) &&
                        (w_sent || axi_w_handshake)) begin
                        state <= ST_WAIT_BRESP;
                    end   
                end
                
                ST_WAIT_BRESP:begin
                    if(axi_b_handshake) begin
                        if(m_bresp == AXI_RESP_OKAY) begin
                            hresp_reg <= 1'b0;
                            state     <= ST_AHB_COMPLETE;
                        end else begin
                            hresp_reg <= 1'b1;
                            state     <= ST_AHB_ERROR_1;
                        end
                    end
                end
                
                ST_AXI_READ: begin
                    if(axi_ar_handshake) 
                        state <= ST_WAIT_RDATA;
                end
                
                ST_WAIT_RDATA :begin
                    if(axi_r_handshake) begin
                        hrdata_reg <= m_rdata;
                        
                        if((m_rresp == AXI_RESP_OKAY)&& m_rlast)begin
                            hresp_reg <= 1'b0;
                            state <= ST_AHB_COMPLETE;
                        end else begin
                            hresp_reg <= 1'b1;
                            state <= ST_AHB_ERROR_1;
                        end
                    end
                end
                
                ST_AHB_ERROR_1: begin
                    // First half of the AHB-Lite two-cycle ERROR response.
                    // The next state completes it with HRESP=1, HREADY=1.
                    state <= ST_AHB_COMPLETE;
                end
                
                ST_AHB_COMPLETE : begin
                    // HREADY is high in this state. At this edge the previous
                    // transfer completes and a following address phase may be
                    // accepted, allowing legal back-to-back AHB requests even
                    // though only one transaction is outstanding internally.
                    aw_sent <= 1'b0;
                    w_sent <= 1'b0;
                    
                    if(ahb_address_valid) begin
                        ahb_addr_reg <= haddr;
                        ahb_write_reg <= hwrite;
                        ahb_size_reg <= hsize;
                        ahb_request_error_reg <= ahb_request_unsupported;
                        hresp_reg <= 1'b0;
                        
                        if(hwrite) begin
                            state <= ST_AHB_WRITE_DATA;
                        end else if(ahb_request_unsupported) begin
                            hresp_reg <= 1'b1;
                            state  <= ST_AHB_ERROR_1;
                        end else begin
                            state <= ST_AXI_READ;
                        end
                    end else begin
                        state <= ST_IDLE;
                    end
                end
                
                default : begin
                    state <= ST_IDLE;
                    ahb_request_error_reg <= 1'b0;
                    aw_sent <= 1'b0;
                    w_sent <= 1'b0;
                    hresp_reg <= 1'b0;
                end
              
            endcase
        end
    end    
    
   // HMASTLOCK and HPROT do not affect the first educational bridge.
    wire unused_ahb_attributes = &{1'b0, hmastlock, hprot,
                                   ahb_write_reg, ahb_size_reg}; 
    
endmodule





























