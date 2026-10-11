`timescale 1ns/1ps

// APB3 UART with two independent, single-clock, 16-byte FIFOs.
// Register offsets (32-bit aligned):
//   0x000 TXDATA W: low byte enters TX FIFO; PREADY waits only when full.
//   0x004 RXDATA R: dequeues one byte; empty => PSLVERR.
//   0x008 STATUS R: bit0 TX_SPACE, bit1 RX_AVAILABLE, bit2 FRAME_ERROR,
//                   bit3 TX_FIFO_EMPTY, bit4 RX_FIFO_FULL.
//                W: bit2=1 clears sticky FRAME_ERROR (W1C).
//   0x00C CTRL   RW: bit0 RX_IRQ_ENABLE, bit1 ERROR_IRQ_ENABLE.
// Other/misaligned accesses complete with PSLVERR. Data at each FIFO head is
// combinationally visible; reads/writes and pointer updates use the same pclk.
module apb_uart #(
    parameter integer CLKS_PER_BIT = 434
) (
    input  wire        pclk,
    input  wire        preset_n,
    
    input  wire [11:0] paddr,
    input  wire        psel,
    input  wire        penable,
    input  wire        pwrite,
    input  wire [31:0] pwdata,
    
    output reg  [31:0] prdata,
    output wire        pready,
    output wire        pslverr,
    
    input  wire        uart_rx,
    output wire        uart_tx,
    output wire        irq,

    // DMA节拍请求：只有RX有数据或TX有空间时才允许DMA发起单拍访问。
    // 这两个信号不改变CPU可见寄存器行为，也不会占用AXI/APB事务。
    output wire        rx_dma_req,
    output wire        tx_dma_req
);
    localparam [9:0] REG_TXDATA = 10'h000;
    localparam [9:0] REG_RXDATA = 10'h001;
    localparam [9:0] REG_STATUS = 10'h002;
    localparam [9:0] REG_CTRL   = 10'h003;

    wire tx_ready, tx_done;
    wire [7:0] rx_data;
    wire rx_valid, frame_error;
    reg [1:0] irq_enable;
    reg frame_error_pending;

    localparam [4:0] FIFO_DEPTH = 5'd16;
    reg [7:0] tx_fifo [0:15];
    reg [7:0] rx_fifo [0:15];
    reg [3:0] tx_wr_ptr, tx_rd_ptr;
    reg [3:0] rx_wr_ptr, rx_rd_ptr;
    reg [4:0] tx_count, rx_count;
    wire tx_empty = (tx_count == 5'd0);
    wire tx_full  = (tx_count == FIFO_DEPTH);
    wire rx_empty = (rx_count == 5'd0);
    wire rx_full  = (rx_count == FIFO_DEPTH);
    wire aligned = (paddr[1:0] == 2'b00);
    wire access = preset_n && psel && penable;
    wire tx_access = access && pwrite && aligned &&
                     (paddr[11:2] == REG_TXDATA);
    wire rx_access = access && !pwrite && aligned &&
                     (paddr[11:2] == REG_RXDATA);

    // APB -> TX FIFO -> serial transmitter. Do not accept a write when full.
    // tx_valid and FIFO-head data remain stable while the transmitter is busy.
    wire tx_valid = !tx_empty;
    wire [7:0] tx_data = tx_fifo[tx_rd_ptr];
    wire tx_pop = tx_valid && tx_ready;
    assign pready = preset_n && !(tx_access && tx_full);
    wire apb_fire = access && pready;
    wire tx_push = apb_fire && tx_access;

    // Serial receiver -> RX FIFO -> APB. Do not depend on a CPU read before
    // accepting a byte; the receiver holds rx_valid while the FIFO is full.
    wire rx_ready = preset_n && !rx_full;
    wire rx_push = rx_valid && rx_ready;
    wire rx_pop = apb_fire && rx_access && !rx_empty;
    wire bad_address = !aligned ||
        (paddr[11:2] != REG_TXDATA && paddr[11:2] != REG_RXDATA &&
         paddr[11:2] != REG_STATUS && paddr[11:2] != REG_CTRL);
    wire bad_direction = (pwrite && (paddr[11:2] == REG_RXDATA)) ||
                         (!pwrite && (paddr[11:2] == REG_TXDATA));
    assign pslverr = apb_fire &&
                     (bad_address || bad_direction ||
                      (rx_access && rx_empty));

    always @* begin
        prdata = 32'd0;
        if (aligned) begin
            case (paddr[11:2])
                REG_RXDATA: if (!rx_empty) prdata = {24'd0, rx_fifo[rx_rd_ptr]};
                REG_STATUS: prdata = {27'd0, rx_full, tx_empty,
                                      frame_error_pending, !rx_empty, !tx_full};
                REG_CTRL:   prdata = {30'd0, irq_enable};
                default:    prdata = 32'd0;
            endcase
        end
    end

    assign irq = preset_n &&
                 ((irq_enable[0] && !rx_empty) ||
                  (irq_enable[1] && frame_error_pending));
    assign rx_dma_req = preset_n && !rx_empty;
    assign tx_dma_req = preset_n && !tx_full;

    uart_tx_byte #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
        .clk(pclk), .reset_n(preset_n),
        .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
        .uart_tx(uart_tx), .tx_done(tx_done)
    );
    uart_rx_byte #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_rx (
        .clk(pclk), .reset_n(preset_n), .uart_rx(uart_rx),
        .rx_data(rx_data), .rx_valid(rx_valid), .rx_ready(rx_ready),
        .frame_error(frame_error)
    );

    // Both FIFOs use pclk. Pointers move on their own handshakes; the count
    // changes only if exactly one of push/pop happens on this clock edge.
    always @(posedge pclk or negedge preset_n) begin
        if (!preset_n) begin
            tx_wr_ptr <= 4'd0;
            tx_rd_ptr <= 4'd0;
            rx_wr_ptr <= 4'd0;
            rx_rd_ptr <= 4'd0;
            tx_count <= 5'd0;
            rx_count <= 5'd0;
        end else begin
            if (tx_push) begin
                tx_fifo[tx_wr_ptr] <= pwdata[7:0];
                tx_wr_ptr <= tx_wr_ptr + 1'b1;
            end
            if (tx_pop)
                tx_rd_ptr <= tx_rd_ptr + 1'b1;
            case ({tx_push, tx_pop})
                2'b10: tx_count <= tx_count + 1'b1;
                2'b01: tx_count <= tx_count - 1'b1;
                default: ; // Both or neither: occupancy is unchanged.
            endcase

            if (rx_push) begin
                rx_fifo[rx_wr_ptr] <= rx_data;
                rx_wr_ptr <= rx_wr_ptr + 1'b1;
            end
            if (rx_pop)
                rx_rd_ptr <= rx_rd_ptr + 1'b1;
            case ({rx_push, rx_pop})
                2'b10: rx_count <= rx_count + 1'b1;
                2'b01: rx_count <= rx_count - 1'b1;
                default: ; // Both or neither: occupancy is unchanged.
            endcase
        end
    end

    always @(posedge pclk or negedge preset_n) begin
        if (!preset_n) begin
            irq_enable <= 2'b00;
            frame_error_pending <= 1'b0;
        end else begin
            if (apb_fire && pwrite && !pslverr && aligned &&
                (paddr[11:2] == REG_CTRL))
                irq_enable <= pwdata[1:0];

            if (apb_fire && pwrite && aligned &&
                (paddr[11:2] == REG_STATUS) && pwdata[2])
                frame_error_pending <= 1'b0;
            if (frame_error)
                frame_error_pending <= 1'b1; // New error wins over W1C.
        end
    end
    wire unused_tx_done = tx_done;
endmodule
