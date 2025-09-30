`timescale 1ns/10ps

module tb;
    localparam realtime period = 1_000_000_000 / 12_000_000;
    logic clk = 0;
    always #(period/2) clk <= ~clk;

    logic reset = 0;

    localparam SCREEN_WIDTH = 32;
    localparam SCREEN_HEIGHT = 32;

    logic vsync;
    logic [15:0] screen_write_x, screen_write_y;
    logic [1:0] [2:0] [3:0] screen_write_rgb;
    logic screen_write_valid;
    logic [2:0] led_rgb_o;
    led_matrix_controller #(
        .WIDTH(SCREEN_WIDTH), .HEIGHT(SCREEN_HEIGHT)
    ) dut (
        .clk_i(clk), .reset_i(reset),
        .screen_write_x_i(screen_write_x), .screen_write_y_i(screen_write_y),
        .screen_write_rgb_i(screen_write_rgb),
        .screen_write_valid_i(screen_write_valid),
        .vsync_o(vsync),
        .led_addr_o(), .led_r_o(), .led_g_o(), .led_b_o(),
        .led_clk_o(), .led_latch_o(), .led_oe_n_o()
    );
    defparam dut.OUTPUT_CLK_DIV = 2;
    defparam dut.COLOR_DEPTH = 4;

    // write to the screen
    initial begin
        screen_write_valid <= 0;
        screen_write_x <= 0;
        screen_write_y <= 0;
        forever begin
            int idx;
            idx = 0;
            @(posedge vsync);

            for (screen_write_y = 0; screen_write_y < SCREEN_HEIGHT; screen_write_y++) begin
                for (screen_write_x = 0; screen_write_x < SCREEN_HEIGHT; screen_write_x += 2) begin
                    @(posedge clk);
                    screen_write_valid <= 1;
                    screen_write_rgb[0][0] <= (((idx / 48) % 3) == 0) ? idx % 16 : 0;
                    screen_write_rgb[0][1] <= (((idx / 48) % 3) == 1) ? idx % 16 : 0;
                    screen_write_rgb[0][2] <= (((idx / 48) % 3) == 2) ? idx % 16 : 0;
                    idx++;
                    screen_write_rgb[1][0] <= (((idx / 48) % 3) == 0) ? idx % 16 : 0;
                    screen_write_rgb[1][1] <= (((idx / 48) % 3) == 1) ? idx % 16 : 0;
                    screen_write_rgb[1][2] <= (((idx / 48) % 3) == 2) ? idx % 16 : 0;
                    idx++;
                    @(posedge clk);
                    screen_write_valid <= 0;
                    repeat (15) @(posedge clk);
                end
            end
        end
    end

    localparam NUM_CLKS = 500_000;
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
