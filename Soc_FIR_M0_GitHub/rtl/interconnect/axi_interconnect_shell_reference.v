`timescale 1ns / 1ps

`include "soc_addr_map.vh"

module axi_interconnect_shell_reference(
    input wire                  clk,
    input wire                  reset_n,
    
    //Upstream AXI write-address channel
    input wire [31:0]           s_awaddr,
    input wire [7:0]            s_awlen,  //传多少拍，实际传输拍数 = s_awlen + 1
    input wire [2:0]            s_awsize, //每拍传输的字节数，这个只有3位，范围是0-7,对应是1-128
    input wire [1:0]            s_awburst,//突发类型
    input wire                  s_awvalid,
    output wire                 s_awready,
    
    //Upstream AXI write-data channel
    input wire [31:0]           s_wdata,
    input wire [3:0]            s_wstrb, //选择要写的字节
    input wire                  s_wlast, //表示这是最后一个字
    input wire                  s_wvalid,
    output wire                 s_wready,
    
    //Upstream AXI write-response channel
    output wire [1:0]           s_bresp, //发送给主机的响应内容
    output wire                 s_bvalid,
    input wire                  s_bready,
    
    //Upstream AXI read-address channel
    input wire [31:0]           s_araddr,
    input wire [7:0]            s_arlen,  //传多少拍，实际传输拍数 = s_awlen + 1
    input wire [2:0]            s_arsize, //每拍传输的字节数，3位，0-7对应是1-128
    input wire [1:0]            s_arburst,//突发类型
    input wire                  s_arvalid,
    output wire                 s_arready,
    
    //Upstream AXI read-data channel
    output wire [31:0]          s_rdata,
    output wire [1:0]           s_rresp,  //响应信息
    output wire                 s_rlast, //是否是最后一个数据
    output wire                 s_rvalid,
    input wire                  s_rready,
    
    //Sticky flag : become 1 after an unmapped request is accepted.
    output reg                  error_seen
    );
    
    localparam [1:0]    TARGET_CODE = 2'd0;
    localparam [1:0]    TARGET_DATA = 2'd1;
    localparam [1:0]    TARGET_ERROR = 2'd2;
    
    localparam [1:0]    AXI_RESP_OKAY = 2'b00;
    localparam [1:0]    AXI_RESP_DECERR = 2'b11;
    
    // --------------------------------------------------------------
    // Address decoding
    // --------------------------------------------------------------
    
    wire aw_select_code;
    wire aw_select_data;
    wire ar_select_code;
    wire ar_select_data;
    
    assign aw_select_code = ((s_awaddr & `SOC_CODE_SRAM_MASK) == `SOC_CODE_SRAM_BASE);
    assign aw_select_data = ((s_awaddr & `SOC_DATA_SRAM_MASK) == `SOC_DATA_SRAM_BASE);
    assign ar_select_code = ((s_araddr & `SOC_CODE_SRAM_MASK) == `SOC_CODE_SRAM_BASE);
    assign ar_select_data = ((s_araddr & `SOC_DATA_SRAM_MASK) == `SOC_DATA_SRAM_BASE); 
    
    // With the current address map these can never both be 1. They are
    // useful waveform signals when checking that the windows do not overlap.   
    wire aw_decode_overlap = aw_select_code && aw_select_data;
    wire ar_decode_overlap = ar_select_code && ar_select_data;
    
    // --------------------------------------------------------------
    // Saved transaction destinations
    // --------------------------------------------------------------     
    
    reg             write_active;
    reg [1:0]       write_target;
    reg             decode_bvalid;
    reg [7:0]       decode_awlen_reg;
    reg [7:0]       decode_write_beat_reg;
    wire            decode_write_expected_last;
    
        
    reg             read_active;
    reg [1:0]       read_target;
    reg             decode_rvalid;
    reg [7:0]       decode_arlen_reg;
    reg [7:0]       decode_read_beat_reg;
    wire           decode_read_expected_last;
    
    assign decode_write_expected_last = (decode_write_beat_reg == decode_awlen_reg);
    assign decode_read_expected_last = (decode_read_beat_reg == decode_arlen_reg);
    // This first version allows only one read OR one write transaction to
    // be active in the complete interconnect. 
    wire interconnect_idle = !write_active && !read_active;
    
    // --------------------------------------------------------------
    // Internal wires for the code SRAM AXI port
    // --------------------------------------------------------------
           
    wire            code_awvalid;
    wire            code_awready;
    wire            code_wvalid;
    wire            code_wready;
    wire [1:0]      code_bresp;
    wire            code_bvalid;
    wire            code_bready;
    
    wire            code_arvalid;
    wire            code_arready;
    wire [31:0]     code_rdata;
    wire [1:0]      code_rresp;
    wire            code_rlast;
    wire            code_rvalid;
    wire            code_rready;
    
    // --------------------------------------------------------------
    // Internal wires for the data SRAM AXI port
    // --------------------------------------------------------------
    
    wire            data_awvalid;
    wire            data_awready;
    wire            data_wvalid;
    wire            data_wready;
    wire [1:0]      data_bresp;
    wire            data_bvalid;
    wire            data_bready;
    
    wire            data_arvalid;
    wire            data_arready;
    wire [31:0]     data_rdata;
    wire [1:0]      data_rresp;
    wire            data_rlast;
    wire            data_rvalid;
    wire            data_rready;        
    
    // --------------------------------------------------------------
    // AW request routing
    // --------------------------------------------------------------

    // Only the selected SRAM sees AWVALID. An unmapped AW is not sent to
    // either SRAM; the interconnect accepts it locally instead.
        
    assign code_awvalid = reset_n && interconnect_idle &&
                          s_awvalid && aw_select_code;
                          
    assign data_awvalid = reset_n && interconnect_idle &&
                          s_awvalid && aw_select_data;
    
    assign s_awready = !reset_n     ? 1'b0          :
                       !interconnect_idle ? 1'b0    :
                       aw_select_code     ? code_awready:
                       aw_select_data     ? data_awready:
                                            1'b1;  //意味着aw地址不在映射范围内，为了防止死锁，需要将从设备ready置为1,后续B通道会返回报错信息
                                                                      
    wire aw_handshake = s_awvalid && s_awready;
    
    // --------------------------------------------------------------
    // W request routing
    // --------------------------------------------------------------

    // W has no address. Therefore it may be routed only after the AW
    // handshake has saved write_target. A W-first master is backpressured
    // and must hold WVALID/WDATA/WSTRB/WLAST until WREADY becomes 1.                           
    
    assign code_wvalid = write_active &&
                         (write_target == TARGET_CODE) &&  s_wvalid;
    assign data_wvalid = write_active &&
                         (write_target == TARGET_DATA) &&  s_wvalid;
                         
    assign s_wready = !reset_n          ?   1'b0 :
                      !write_active     ?   1'b0 :
                      (write_target == TARGET_CODE) ? code_wready :
                      (write_target == TARGET_DATA) ? data_wready :
                      (write_target == TARGET_ERROR)? !decode_bvalid :
                                                        1'b0;  //前面已经包含了所有情况，如果上述情况都不满足则置为0
    
    wire w_handshake = s_wvalid && s_wready;
    
    // --------------------------------------------------------------
    // B response selection
    // --------------------------------------------------------------
    
    // BREADY is returned only to the slave that owns this write.    
    assign code_bready = write_active && 
                         (write_target == TARGET_CODE) && s_bready;
    assign data_bready = write_active &&
                         (write_target == TARGET_DATA) && s_bready;

    // The saved target selects exactly one source for BVALID/BRESP.                      
    
    assign  s_bvalid = !write_active        ?   1'b0 :
                       (write_target == TARGET_CODE ) ? code_bvalid :
                       (write_target == TARGET_DATA)  ? data_bvalid :
                       (write_target == TARGET_ERROR) ? decode_bvalid:
                                                        1'b0;
                                                        
    assign s_bresp = !write_active      ? AXI_RESP_OKAY:
                     (write_target == TARGET_CODE ) ? code_bresp :
                     (write_target == TARGET_DATA)  ? data_bresp :
                     (write_target == TARGET_ERROR) ? AXI_RESP_DECERR :
                                                      AXI_RESP_OKAY;                                                     
    wire b_handshake = s_bvalid && s_bready;
    
    // Save the write target from the AW handshake through the B handshake. 
    always@(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            write_active <= 1'b0;
            write_target <= TARGET_ERROR;
            decode_bvalid <= 1'b0;
            decode_awlen_reg <= 8'd0;
            decode_write_beat_reg <= 8'd0;
        end else begin
            if(!write_active && aw_handshake) begin
                write_active <= 1'b1;
                decode_awlen_reg <= s_awlen;
                decode_write_beat_reg <= 8'd0;
                decode_bvalid <= 1'b0;
                
                if(aw_select_code)
                   write_target <= TARGET_CODE;
                else if(aw_select_data)
                   write_target <= TARGET_DATA;
                else 
                   write_target <= TARGET_ERROR;
            end
            
            // For an unmapped write, consume exactly one W beat locally,
            // then produce BVALID with BRESP=DECERR.
            if(write_active &&
               (write_target== TARGET_ERROR) && w_handshake) 
               if(decode_write_expected_last) begin
                   decode_bvalid <= 1'b1;
               end else begin
                   decode_write_beat_reg <= decode_write_beat_reg + 8'd1;
               end
            if(b_handshake) begin
                write_active <= 1'b0;
                decode_bvalid <= 1'b0;
            end
        end    
    end  
    
    // --------------------------------------------------------------
    // AR request routing
    // -------------------------------------------------------------
    
    // IF AWVALID and ARVALID arrive together ,the write is accepted first.   
    
    wire read_address_allowed = reset_n && interconnect_idle && !s_awvalid;
    
    assign code_arvalid = read_address_allowed &&
                          s_arvalid && ar_select_code;
                      
    assign data_arvalid = read_address_allowed &&
                          s_arvalid && ar_select_data;
                          
    assign s_arready = !read_address_allowed    ?   1'b0:
                       ar_select_code           ?   code_arready :
                       ar_select_data           ?   data_arready :
                                                    1'b1;
                                                       
    wire ar_handshake = s_arvalid && s_arready;
    
    // --------------------------------------------------------------
    // R response selection
    // --------------------------------------------------------------
    
    assign code_rready = read_active &&
                        (read_target == TARGET_CODE) && s_rready;
                        
    assign data_rready = read_active &&
                        (read_target == TARGET_DATA) && s_rready;
                       
    assign s_rvalid = !read_active      ?   1'b0:
                      (read_target == TARGET_CODE) ? code_rvalid :
                      (read_target == TARGET_DATA) ? data_rvalid :
                      (read_target == TARGET_ERROR)? decode_rvalid:
                                                      1'b0;       
    assign s_rdata = !read_active       ?    32'b0:
                     (read_target == TARGET_CODE) ? code_rdata:
                     (read_target == TARGET_DATA) ? data_rdata:
                                                   32'b0;
                                                   
    assign s_rresp = !read_active   ?  AXI_RESP_OKAY :
                     (read_target == TARGET_CODE )  ? code_rresp:
                     (read_target == TARGET_DATA)   ? data_rresp:
                     (read_target == TARGET_ERROR)  ? AXI_RESP_DECERR:
                                                      AXI_RESP_OKAY;
                                
    assign s_rlast = !read_active ? 1'b0 :
                     (read_target == TARGET_CODE) ? code_rlast :
                     (read_target == TARGET_DATA) ? data_rlast :
                     (read_target == TARGET_ERROR)? decode_read_expected_last:
                                                    1'b0;
   
   wire r_handshake = s_rvalid && s_rready;
   
   // Save the read target from the AR handshake through the R handshake.   
   always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            read_active <= 1'b0;
            read_target <= TARGET_ERROR;
            decode_rvalid <= 1'b0;
            decode_arlen_reg <= 8'd0;
            decode_read_beat_reg <= 8'd0;
        end else begin
            if(!read_active && ar_handshake) begin
                read_active <= 1'b1;
                decode_arlen_reg <= s_arlen;
                decode_read_beat_reg <= 8'd0;
                decode_rvalid <= 1'b0;
                
                if(ar_select_code) 
                    read_target <= TARGET_CODE;
                else if(ar_select_data) 
                    read_target <= TARGET_DATA;
                else begin
                    read_target <= TARGET_ERROR;
                    decode_rvalid <= 1'b1;
                end 
            end
         
         if(r_handshake) begin
            if(s_rlast) begin
               read_active <= 1'b0;
               decode_rvalid <= 1'b0;           
            end else if(read_target == TARGET_ERROR) begin
               decode_read_beat_reg <= decode_read_beat_reg + 8'd1;
            end    
         end
        end
   end       
   
   //Record an ummapped access. This flag stays high until reset.
   always@(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            error_seen <= 1'b0;
        end else begin
            if(aw_handshake && !aw_select_code && !aw_select_data) 
                error_seen <= 1'b1;
                
            if(ar_handshake && !ar_select_code && !ar_select_data) 
                error_seen <= 1'b1;
        end
   end                                          
                                                                                                                                                                                                                                                                                 
    // --------------------------------------------------------------
    // Two independent 64 KiB SRAM slaves
    // --------------------------------------------------------------

    // 64 KiB / 4 bytes per word = 16384 words = 2^14 words.
    axi_burst_sram #(
        .SRAM_ADDR_WIDTH(14)
    ) u_code_sram (
        .clk       (clk),
        .reset_n   (reset_n),

        .s_awaddr  (s_awaddr),
        .s_awlen   (s_awlen),
        .s_awsize  (s_awsize),
        .s_awburst (s_awburst),
        .s_awvalid (code_awvalid),
        .s_awready (code_awready),

        .s_wdata   (s_wdata),
        .s_wstrb   (s_wstrb),
        .s_wlast   (s_wlast),
        .s_wvalid  (code_wvalid),
        .s_wready  (code_wready),

        .s_bresp   (code_bresp),
        .s_bvalid  (code_bvalid),
        .s_bready  (code_bready),

        .s_araddr  (s_araddr),
        .s_arlen   (s_arlen),
        .s_arsize  (s_arsize),
        .s_arburst (s_arburst),
        .s_arvalid (code_arvalid),
        .s_arready (code_arready),

        .s_rdata   (code_rdata),
        .s_rresp   (code_rresp),
        .s_rlast   (code_rlast),
        .s_rvalid  (code_rvalid),
        .s_rready  (code_rready)
    );

    axi_burst_sram #(
        .SRAM_ADDR_WIDTH(14)
    ) u_data_sram (
        .clk       (clk),
        .reset_n   (reset_n),

        .s_awaddr  (s_awaddr),
        .s_awlen   (s_awlen),
        .s_awsize  (s_awsize),
        .s_awburst (s_awburst),
        .s_awvalid (data_awvalid),
        .s_awready (data_awready),

        .s_wdata   (s_wdata),
        .s_wstrb   (s_wstrb),
        .s_wlast   (s_wlast),
        .s_wvalid  (data_wvalid),
        .s_wready  (data_wready),

        .s_bresp   (data_bresp),
        .s_bvalid  (data_bvalid),
        .s_bready  (data_bready),

        .s_araddr  (s_araddr),
        .s_arlen   (s_arlen),
        .s_arsize  (s_arsize),
        .s_arburst (s_arburst),
        .s_arvalid (data_arvalid),
        .s_arready (data_arready),

        .s_rdata   (data_rdata),
        .s_rresp   (data_rresp),
        .s_rlast   (data_rlast),
        .s_rvalid  (data_rvalid),
        .s_rready  (data_rready)
    );

    // Prevent unused-signal warnings in this educational, single-beat shell.
    // The attributes are still forwarded to axi_sram, which checks AWLEN,
    // ARLEN and WLAST and returns SLVERR for unsupported transfers.
     wire unused_decode_overlap = &{1'b0,
                               aw_decode_overlap,
                               ar_decode_overlap};
                              
endmodule
    
    
    







































