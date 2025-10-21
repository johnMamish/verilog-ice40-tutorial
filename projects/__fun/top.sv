`timescale 1ns/10ps

/**
 * This utility module will emit a reset signal shortly after power-up.
 * It takes advantage of the iCE40's initial / reset capabilities on
 * power-up.
 */
module reset_generator #(
    parameter RESET_MAX = 500
)  (
    input clk_i,
    output logic reset_o
);
    logic [8:0] reset_counter;
    initial reset_counter = 0;
    initial reset_o = 1;

    always_ff @(posedge clk_i) begin
        if (reset_counter != RESET_MAX) begin
            reset_counter <= reset_counter + 1;
        end else begin
            reset_o <= 0;
        end
    end
endmodule

module top #(
    parameter LED_CLK_DIV = 4
)  (
    input clk_i,

    input uart_rx_i,
    output logic uart_tx_o,

    output [4:0] led_addr_o,
    output [1:0] led_r_o,
    output [1:0] led_g_o,
    output [1:0] led_b_o,
    output       led_clk_o,
    output       led_latch_o,
    output       led_oe_n_o
);
    logic reset;
    reset_generator reset_generator_inst (
        .clk_i, .reset_o(reset)
    );

    logic led_matrix_vsync;

    ////////////////////////////////////////////////////////////////
    // uart rx
    localparam SCREEN_WIDTH = 64;
    localparam SCREEN_HEIGHT = 64;
    logic uart_rxdata_valid;
    logic [7:0] uart_rxdata;

    uart_rx uart_rx_inst (
        .clk_i(clk_i), .reset_i(reset),
        .uart_rx_i(uart_rx_i),
        .rxdata_valid_o(uart_rxdata_valid), .rxdata_o(uart_rxdata),
        .uart_busy_o()
    );
    defparam uart_rx_inst.CLK_DIVIDER = (12_000_000 / 2_000_000);

    ////////////////////////////////////////////////////////////////
    // send rx bytes (RGB 444) to led matrix
    logic screen_write_valid;
    logic [1:0] [2:0] [3:0] rgb_latch;
    logic [7:0] rgb_x_index, rgb_y_index, rgb_color_index;
    always_ff @(posedge clk_i) begin
        screen_write_valid <= 0;

        if (uart_rxdata_valid) begin
            case (rgb_color_index)
                0: {rgb_latch[0][1][0 +: 4], rgb_latch[0][0][0 +: 4]} <= uart_rxdata;
                1: {rgb_latch[1][0][0 +: 4], rgb_latch[0][2][0 +: 4]} <= uart_rxdata;
                2: {rgb_latch[1][2][0 +: 4], rgb_latch[1][1][0 +: 4]} <= uart_rxdata;
            endcase

            if (rgb_color_index == 2) rgb_color_index <= 0;
            else rgb_color_index <= rgb_color_index + 1;

            // next cycle writes to screen
            if (rgb_color_index == 2) screen_write_valid <= 1;
        end

        // increment pixel index after screen write valid
        if (screen_write_valid) begin
            rgb_x_index <= rgb_x_index + 2;
            if (rgb_x_index == (SCREEN_WIDTH - 2)) begin
                rgb_x_index <= 0;
                rgb_y_index <= rgb_y_index + 1;
                if (rgb_y_index == (SCREEN_HEIGHT - 1)) begin
                    rgb_y_index <= 0;
                end
            end
        end

        if (led_matrix_vsync) begin
            rgb_y_index <= 0;
            rgb_x_index <= 0;
            rgb_color_index <= 0;
        end

        if (reset) begin
            screen_write_valid <= 0;
            rgb_latch <= '0;
            {rgb_x_index, rgb_y_index, rgb_color_index} <= '0;
        end
    end

    ////////////////////////////////////////////////////////////////
    // LED matrix controller
    led_matrix_controller lmc (
        .clk_i, .reset_i(reset),
        .screen_write_x_i(rgb_x_index), .screen_write_y_i(rgb_y_index),
        .screen_write_rgb_i(rgb_latch),
        .screen_write_valid_i(screen_write_valid),
        .vsync_o(led_matrix_vsync),
        .led_addr_o, .led_r_o, .led_g_o, .led_b_o, .led_clk_o, .led_latch_o, .led_oe_n_o
    );
    defparam lmc.OUTPUT_CLK_DIV = LED_CLK_DIV;
    defparam lmc.WIDTH = SCREEN_WIDTH;
    defparam lmc.HEIGHT = SCREEN_HEIGHT;
    defparam lmc.COLOR_DEPTH = 4;
    defparam lmc.SCAN_RATIO = 32;

    ////////////////////////////////////////////////////////////////
    // uart tx
    // every vsync, we send a carriage return
    uart_tx uart_tx_inst (
        .clk_i(clk_i), .reset_i(reset),
        .txdata_valid_i(led_matrix_vsync), .txdata_i(8'h0d),
        .uart_busy_o(), .uart_tx_o(uart_tx_o)
    );
    defparam uart_tx_inst.CLK_DIVIDER = (12_000_000 / 2_000_000);
endmodule

module top2 (
    input clk_i,

    input uart_rx_i,
    output logic uart_tx_o,

    output [4:0] led_addr_o,
    output [1:0] led_r_o,
    output [1:0] led_g_o,
    output [1:0] led_b_o,
    output       led_clk_o,
    output       led_latch_o,
    output       led_oe_n_o
);
    logic reset;
    reset_generator reset_generator_inst (
        .clk_i, .reset_o(reset)
    );

    logic [63:0] [5:0] line_memory;
    initial begin
        line_memory
          = {
            6'b111111, 6'b101101, 6'b110110, 6'b011011,
            6'b100100, 6'b010010, 6'b001001, 6'b000000,
            6'b111111, 6'b101101, 6'b110110, 6'b011011,
            6'b100100, 6'b010010, 6'b001001, 6'b000000,

            6'b111111, 6'b101101, 6'b110110, 6'b011011,
            6'b100100, 6'b010010, 6'b001001, 6'b000000,
            6'b111111, 6'b101101, 6'b110110, 6'b011011,
            6'b100100, 6'b010010, 6'b001001, 6'b000000,

            6'b111111, 6'b101101, 6'b110110, 6'b011011,
            6'b100100, 6'b010010, 6'b001001, 6'b000000,
            6'b111111, 6'b101101, 6'b110110, 6'b011011,
            6'b100100, 6'b010010, 6'b001001, 6'b000000,

            6'b111111, 6'b101101, 6'b110110, 6'b011011,
            6'b100100, 6'b010010, 6'b001001, 6'b000000,
            6'b111111, 6'b101101, 6'b110110, 6'b011011,
            6'b100100, 6'b010010, 6'b001001, 6'b000000
        };
    end

    enum logic [2:0] {
        STATE_TX,
        STATE_LATCH,
        STATE_DWELL
    } state;

    localparam CLOCK_DIVIDER = 6;
    logic [7:0] row_counter;
    logic [15:0] pixel_counter;
    logic [31:0] clock_counter;
    always_ff @(posedge clk_i) begin
        clock_counter <= clock_counter + 1;

        if ((state == STATE_TX) && (clock_counter == ((CLOCK_DIVIDER >> 2) - 1))) begin
            {led_b_o[1], led_g_o[1], led_r_o[1], led_b_o[0], led_g_o[0], led_r_o[0]}
              <= line_memory[pixel_counter[0 +: 6]];
            led_clk_o <= 0;
        end

        if ((state == STATE_TX) && (clock_counter == (CLOCK_DIVIDER - 1))) begin
            led_clk_o <= 1;
            pixel_counter <= pixel_counter + 1;
            if (pixel_counter == (64 - 1)) begin
                row_counter <= row_counter + 1;
                pixel_counter <= 0;
                led_addr_o <= led_addr_o + 1;
                state <= STATE_LATCH;
            end

            clock_counter <= 0;
        end

        if (state == STATE_LATCH) begin
            led_latch_o <= 1;
            if (clock_counter == 5) begin
                led_latch_o <= 0;
                clock_counter <= 0;
                state <= STATE_DWELL;
            end
        end

        if (state == STATE_DWELL) begin
            led_oe_n_o <= 0;
            if (clock_counter == 1000) begin
                led_oe_n_o <= 1;
                clock_counter <= 0;
                state <= STATE_TX;
            end
        end

        if (reset) begin
            clock_counter <= 0;
            pixel_counter <= 0;
            state <= STATE_DWELL;
            row_counter <= 0;
        end
    end
endmodule
