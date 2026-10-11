`timescale 1ns/1ps

module tb_apb_uart_fifo;
    localparam integer CPB = 16;
    reg clk = 0;
    always #5 clk = ~clk;
    reg reset_n = 0;
    reg [11:0] paddr = 0;
    reg psel = 0, penable = 0, pwrite = 0;
    reg [31:0] pwdata = 0;
    wire [31:0] prdata;
    wire pready, pslverr;
    reg uart_rx = 1;
    wire uart_tx, irq;
    integer checks = 0;
    integer stalls;
    integer i;
    reg err;
    reg [31:0] value;
    reg monitor_start = 0;
    reg monitor_done = 0;

    apb_uart_shell #(.CLKS_PER_BIT(CPB)) dut (
        .pclk(clk), .preset_n(reset_n),
        .paddr(paddr), .psel(psel), .penable(penable),
        .pwrite(pwrite), .pwdata(pwdata),
        .prdata(prdata), .pready(pready), .pslverr(pslverr),
        .uart_rx(uart_rx), .uart_tx(uart_tx), .irq(irq)
    );

    task automatic check(input bit condition, input string message);
        begin
            checks = checks + 1;
            if (!condition) $fatal(1, "TEST FAIL: %s at %0t", message, $time);
        end
    endtask

    task automatic apb_write(input [11:0] addr, input [31:0] data,
                             output reg error_seen, output integer wait_cycles);
        reg done;
        begin
            @(negedge clk);
            paddr = addr; pwdata = data; pwrite = 1; psel = 1; penable = 0;
            @(negedge clk);
            penable = 1;
            done = 0; wait_cycles = 0; error_seen = 0;
            while (!done) begin
                @(posedge clk);
                if (pready) begin
                    error_seen = pslverr;
                    done = 1;
                end else begin
                    wait_cycles = wait_cycles + 1;
                    check(paddr == addr && pwdata == data && psel && penable,
                          "APB write address/data stable while stalled");
                    if (wait_cycles > 250) $fatal(1, "APB write timeout");
                end
            end
            @(negedge clk);
            psel = 0; penable = 0; pwrite = 0;
        end
    endtask

    task automatic apb_read(input [11:0] addr,
                            output reg [31:0] data_seen,
                            output reg error_seen);
        begin
            @(negedge clk);
            paddr = addr; pwdata = 0; pwrite = 0; psel = 1; penable = 0;
            @(negedge clk);
            penable = 1;
            @(posedge clk);
            check(pready, "APB read completes without wait");
            data_seen = prdata; // Sample before the FIFO read-pointer NBA.
            error_seen = pslverr;
            @(negedge clk);
            psel = 0; penable = 0;
        end
    endtask

    task automatic send_rx(input [7:0] data, input bit bad_stop);
        integer bit_no;
        begin
            @(negedge clk); uart_rx = 0;
            repeat (CPB) @(negedge clk);
            for (bit_no = 0; bit_no < 8; bit_no = bit_no + 1) begin
                uart_rx = data[bit_no];
                repeat (CPB) @(negedge clk);
            end
            uart_rx = bad_stop ? 0 : 1;
            repeat (CPB) @(negedge clk);
            uart_rx = 1;
            repeat (4) @(negedge clk);
        end
    endtask

    task automatic expect_tx(input [7:0] expected);
        integer bit_no;
        begin
            @(negedge uart_tx);
            repeat (CPB/2) @(posedge clk);
            check(uart_tx === 0, "TX start bit");
            for (bit_no = 0; bit_no < 8; bit_no = bit_no + 1) begin
                repeat (CPB) @(posedge clk);
                check(uart_tx === expected[bit_no], "TX data bit/order");
            end
            repeat (CPB) @(posedge clk);
            check(uart_tx === 1, "TX stop bit");
        end
    endtask

    initial begin
        wait(monitor_start);
        for (integer n = 0; n < 18; n = n + 1)
            expect_tx(8'h80 + n);
        monitor_done = 1;
    end

    initial begin
        #200000;
        $fatal(1, "TEST FAIL: global timeout");
    end

    initial begin
        $display("[TB] Dual 16-byte single-clock FIFO APB UART");
        repeat (5) @(posedge clk);
        @(negedge clk); reset_n = 1;

        apb_read(12'h008, value, err);
        check(!err && value[0] && !value[1] && value[3] && !value[4],
              "reset status: TX space/empty, RX empty/not full");
        apb_read(12'h004, value, err);
        check(err, "empty RXDATA read returns PSLVERR");
        apb_read(12'h010, value, err);
        check(err, "unmapped register returns PSLVERR");
        apb_write(12'h001, 32'h55, err, stalls);
        check(err, "misaligned TXDATA write returns PSLVERR");
        apb_write(12'h004, 32'h55, err, stalls);
        check(err, "write to RXDATA returns PSLVERR");

        apb_write(12'h00c, 32'h3, err, stalls);
        check(!err, "CTRL enables RX and error IRQ");
        apb_read(12'h00c, value, err);
        check(!err && value == 3, "CTRL readback");

        $display("[TB] RX queue keeps multiple bytes until APB reads them");
        send_rx(8'h41, 0);
        send_rx(8'h00, 0);
        send_rx(8'hff, 0);
        check(irq, "RX nonempty raises IRQ");
        apb_read(12'h008, value, err);
        check(!err && value[1], "RX_AVAILABLE status");
        apb_read(12'h004, value, err);
        check(!err && value == 8'h41, "RX first byte");
        apb_read(12'h004, value, err);
        check(!err && value == 8'h00, "RX second byte");
        apb_read(12'h004, value, err);
        check(!err && value == 8'hff, "RX third byte");
        @(posedge clk); #1;
        check(!irq, "RX IRQ clears after FIFO drains");

        send_rx(8'h23, 1);
        apb_read(12'h008, value, err);
        check(!err && value[2] && !value[1] && irq,
              "bad stop sets sticky frame error/IRQ without enqueuing");
        apb_write(12'h008, 32'h4, err, stalls);
        check(!err, "STATUS W1C accepted");
        apb_read(12'h008, value, err);
        check(!err && !value[2] && !irq, "W1C clears frame error IRQ");

        $display("[TB] TX FIFO queues quickly, then stalls only when full");
        monitor_start = 1;
        for (i = 0; i < 17; i = i + 1) begin
            apb_write(12'h000, 32'h80 + i, err, stalls);
            check(!err && stalls == 0, "TX write accepted while FIFO has space");
        end
        apb_read(12'h008, value, err);
        check(!err && !value[0] && !value[3], "TX FIFO full, not empty");
        apb_write(12'h000, 32'h91, err, stalls);
        check(!err && stalls > 0, "full TX FIFO stretches APB write");
        wait(monitor_done);
        repeat (CPB) @(posedge clk);
        apb_read(12'h008, value, err);
        check(!err && value[0] && value[3], "TX FIFO drains in order");

        $display("[TB] RX FIFO full and held 17th byte");
        for (i = 0; i < 17; i = i + 1)
            send_rx(8'h40 + i, 0);
        check(dut.u_apb_uart.rx_count == 16 && dut.u_apb_uart.rx_valid,
              "16 bytes queued; 17th held by RX engine");
        apb_read(12'h008, value, err);
        check(!err && value[4], "RX_FULL status");
        for (i = 0; i < 17; i = i + 1) begin
            apb_read(12'h004, value, err);
            check(!err && value == (8'h40 + i),
                  "RX byte order preserved across pointer wrap");
        end
        apb_read(12'h008, value, err);
        check(!err && !value[1] && !value[4], "RX FIFO fully drained");

        $display("[TB] Reset flushes both queues and sticky state");
        send_rx(8'h5a, 0);
        apb_write(12'h000, 32'h33, err, stalls);
        check(!err && irq, "pending RX and TX before reset");
        @(negedge clk); reset_n = 0;
        repeat (4) @(posedge clk);
        check(uart_tx && !irq, "reset forces TX idle and IRQ low");
        @(negedge clk); reset_n = 1;
        apb_read(12'h008, value, err);
        check(!err && value[0] && !value[1] && value[3] && !value[2],
              "reset clears queued data and frame error");
        apb_read(12'h004, value, err);
        check(err, "old RX byte not visible after reset");

        $display("TEST PASS: APB UART dual FIFO, %0d checks", checks);
        $finish;
    end
endmodule
