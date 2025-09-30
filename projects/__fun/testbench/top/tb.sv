`timescale 1ns/10ps

module tb;
    localparam realtime period = 1_000_000_000 / 12_000_000;
    logic clk = 0;
    always #(period/2) clk <= ~clk;

    logic reset = 0;

    localparam SCREEN_WIDTH = 64;
    localparam SCREEN_HEIGHT = 64;

    ////////////////////////////////////////////////////////////////
    // DUT
    logic uart_tx, uart_rx;
    logic [4:0] led_addr_o;
    logic [1:0] led_r_o, led_g_o, led_b_o;
    logic led_clk_o, led_latch_o, led_oe_n_o;
    top #(
        .LED_CLK_DIV(4)
    ) dut (
        .clk_i(clk),
        .uart_rx_i(uart_tx), .uart_tx_o(uart_rx),

        .led_addr_o, .led_r_o, .led_g_o, .led_b_o,
        .led_clk_o, .led_latch_o, .led_oe_n_o
    );

    ////////////////////////////////////////////////////////////////
    // uarts
    logic [7:0] uart_txdata;
    logic txdata_valid, uart_tx_busy;
    uart_tx #(
        .CLK_DIVIDER(6)
    ) uart_tx_inst (
        .clk_i(clk), .reset_i(reset),
        .txdata_valid_i(txdata_valid), .txdata_i(uart_txdata),
        .uart_busy_o(uart_tx_busy), .uart_tx_o(uart_tx)
    );

    logic uart_rx_valid;          // hsync signal
    uart_rx #(
        .CLK_DIVIDER(6)
    ) uart_rx_inst (
        .clk_i(clk), .reset_i(reset),
        .uart_rx_i(uart_rx),
        .rxdata_valid_o(uart_rx_valid), .rxdata_o(), .uart_busy_o()
    );

    ////////////////////////////////////////////////////////////////
    // send video data
    logic [7:0] data_mem [3 * 64 * 64 / 2];
    initial $readmemh("test_image.hex", data_mem);

    initial begin
        txdata_valid <= 0;
        @(negedge reset);
        repeat (100) @(posedge clk);

        forever begin
            // wait for vsync
            @(posedge uart_rx_valid);

            // send data
            for (int i = 0; i < (3 * 64 * 64 / 2); i++) begin
                while (uart_tx_busy) @(negedge uart_tx_busy);
                @(posedge clk);
                txdata_valid <= 1;
                uart_txdata <= data_mem[i];
                @(posedge clk);
                txdata_valid <= 0;
                @(posedge clk);
            end
        end
    end

    localparam NUM_CLKS = 2_000_000;
    localparam NUM_LOOPS = NUM_CLKS / 100_000;
    initial begin
        $dumpfile("dump.vcd");
        $dumpvars(0, tb);

        reset <= 1;
        repeat (2) @(posedge clk);
        reset <= 0;

        for (int i = 0; i < NUM_LOOPS; i++) begin
            $display("%4d / %4d", i, NUM_LOOPS);
            repeat(100_000) @(posedge clk);
        end
        $finish;
    end
endmodule
