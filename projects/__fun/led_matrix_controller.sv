`timescale 1ns/100ps

/**
 * Returns the column that a given pixel is in
 */
function logic [15:0] zigzag (
    logic [10:0] x, logic [3:0] panel_width_clog2, logic [2:0] panel_x_chain, logic y
);
    logic [10:0] subpanel_x;
    logic [10:0] panel_x;
    logic [10:0] subpanel_col;

    subpanel_x = x & ((1 << panel_width_clog2) - 1);
    panel_x = x[panel_width_clog2 +: 3] << 1;

    if (y) begin
        subpanel_col = (1 << (panel_width_clog2 - 1)) + x;
    end else begin
        if (x < (1 << panel_width_clog2 - 1)) subpanel_col = x;
        else subpanel_col = (1 << (panel_width_clog2)) + x;
    end

    //return subpanel_col + panel_x;
    zigzag = subpanel_col + panel_x;
endfunction

function logic [15:0] xy_loc_to_base_memory_address (
    logic [15:0] x, logic [15:0] y, int panel_width_clog2, int panel_height_clog2, int scan_ratio_clog2
);
    // how many "rows" do we have when shifting out a single "address"?
    int packed_row, packed_col;
    int extra_col;
    int zigzag_needed;

    zigzag_needed = (panel_height_clog2 > (scan_ratio_clog2 + 1));

    // which row are we on?
    // If we have a 1:8 scan ratio on a 32 row panel, rows 0 and 8 are contiguous.
    // If we have a 1:16 scan ratio on a 32 row panel, row 0 doesn't have another row contiguous
    packed_row = y & ((1 << scan_ratio_clog2) - 1);

    // compensate for the fact that the panel is split into 2 large parallel rows with the
    // 2 parallel rgb busses.
    //y = {y[panel_height_clog2 +: (16 - panel_height_clog2)], y[0 +: (panel_height_clog2 - 1)]};
    y = y & ((1 << (panel_height_clog2 - 1)) - 1);

    // how many zigs need to be zagged?
    // should nominally be 0 or 1. Assumes that panel_height is >= 2 * scan_ratio.
    if (!zigzag_needed) extra_col = 0;
    else extra_col = y[scan_ratio_clog2 +: 1];

    // zag the zigs
    if (zigzag_needed) packed_col = zigzag(x, panel_width_clog2, 0, extra_col);
    else packed_col = x;

    // calculate the final index.
    //return (packed_row << (panel_width_clog2 + zigzag_needed)) + packed_col;
    xy_loc_to_base_memory_address = (packed_row << (panel_width_clog2 + zigzag_needed)) + packed_col;
endfunction

function logic xy_loc_to_buffer_half (
    logic [15:0] x, logic [15:0] y, int panel_width_clog2, int panel_height_clog2, int scan_ratio_clog2
);
    if ((y & (1 << (panel_height_clog2 - 1))) == '0) xy_loc_to_buffer_half = 0;
    else xy_loc_to_buffer_half = 1;
endfunction

/**
 * internal memory
 * Architecting this to avoid read and write conflicts is a little tricky. Because the write
 * and read busses have different locality requirements, getting the required ports right is
 * difficult.
 *
 * If we want to have single-cycle writes and reads, we would need a total of 2 * COLOR_DEPTH
 * different read/write ports. This isn't really feasible with the iCE40.
 * For writes, we need to be able to simultaneously write all bit-planes and 3 colors, but for
 * reads we need to be able to read only a single bit-plane but pixels from 2 different locations.
 * This means that we need 2 * COLOR_DEPTH ports.
 *
 * To get "around" this, we take advantage of the fact that writes will be by necessity at most
 * one bit per clock cycle. Each pixel that we specify will be written to scattered memory locations
 * where different bit-planes are non-contiguous.
 *
 * Furthermore, we require that 2 subsequent pixels be written simultaneously. You can't write
 * just the pixel at (x,y), you need to write pixels (x,y) and (x+1,y) at the same time, where
 * x is a multiple of 2.
 *
 * memory 0
 *    (bitplane 0)
 *    r_0,0     g_0,0     b_0,0     xxxx      r_1,0     g_1,0     b_1,0     xxxx
 *    r_2,0     g_2,0     b_2,0     xxxx      r_3,0     g_3,0     b_3,0     xxxx
 *    ......  Then we have height/2 more pixels, stored in zig-zagged and row-major order
 *    ......  We have height/2 because there are 2 rgb busses in parallel, one for the top half
 *    ......  of the screen and one for the bottom half.
 *
 *    (bitplane 1)
 *    r_0,1     g_0,1     b_0,1     xxxx      r_1,1     g_1,1     b_1,1     xxxx
 *    r_2,1     g_2,1     b_2,1     xxxx      r_3,1     g_3,1     b_3,1     xxxx
 *    ......
 *
 * memory 1
 *    (bitplane 0)
 *    r_h/2,0   g_h/2,0   b_h/2,0   xxxx      r_h/2+1,0 g_h/2+1,0 b_h/2+1,0 xxxx
 *    ......
 *
 * The read port serves up subsequent pixels automatically. When "do_read_i" is high, the screen
 * memory controller advances to the next pixel.
 *
 * The 'swap_buffer_i' input resets the readout.
 *
 * TODO: make sure that it's using SPRAM.
 */
module screen_memory #(
    parameter PANEL_WIDTH = 32,
    parameter PANEL_HEIGHT = 32,
    parameter COLOR_DEPTH = 8,
    parameter SCAN_RATIO = 8
)  (
    input clk_i, reset_i,

    // write port
    input [15:0] screen_write_x_i, screen_write_y_i,
    input [1:0] [2:0] [(COLOR_DEPTH-1):0] screen_write_rgb_i,
    input screen_write_valid_i,

    // read port
    // which buffer is active? The other buffer will be the backbuffer that's written to.
    input active_buffer_i,
    input [3:0] read_bitplane_i,
    input [15:0] read_pointer_i,
    input do_read_i,
    output logic [1:0] [2:0] rgb_pixel_o
);
    // one front / backbuffer
    // one buffer for each of {R,G,B}_{1,2} busses
    // one bitplane for each bit of color depth
    // WIDTH*HEIGHT / 2 / 2 total bytes (each nybble contains one bit for r, g, and b, and one unused bit)
    logic [7:0] screen_buffer [2] [2] [COLOR_DEPTH] [(PANEL_WIDTH * PANEL_HEIGHT)/2/2];

    // we have to have the read and write logic in the same always_ff block because they write to
    // the same memory.
    logic active_buffer, back_buffer;
    logic screen_latch_valid, back_buffer_latch;
    logic target_half_latch;
    logic [7:0] write_bitplane_idx;
    logic [1:0] [2:0] [(COLOR_DEPTH-1):0] screen_write_rgb_latch;
    logic [15:0] screen_write_idx_latch;
    always_ff @(posedge clk_i) begin
        active_buffer <= active_buffer_i;
        back_buffer <= ~active_buffer_i;

        ////////////////////////////////////////////////////////////////
        // read logic
        if (do_read_i) begin
            // output new pixel and advance read pointer.
            rgb_pixel_o[0] <= screen_buffer[active_buffer][0][read_bitplane_i][(read_pointer_i >> 1)][read_pointer_i[0] * 4 +: 3];
            rgb_pixel_o[1] <= screen_buffer[active_buffer][1][read_bitplane_i][(read_pointer_i >> 1)][read_pointer_i[0] * 4 +: 3];
        end

        ////////////////////////////////////////////////////////////////
        // write logic
        if (screen_write_valid_i) begin
            screen_write_rgb_latch <= screen_write_rgb_i;
            screen_write_idx_latch <= xy_loc_to_base_memory_address(
                                      screen_write_x_i, screen_write_y_i,
                                      $clog2(PANEL_WIDTH), $clog2(PANEL_HEIGHT),
                                      $clog2(SCAN_RATIO));
            target_half_latch <= xy_loc_to_buffer_half(
                                      screen_write_x_i, screen_write_y_i,
                                      $clog2(PANEL_WIDTH), $clog2(PANEL_HEIGHT),
                                      $clog2(SCAN_RATIO));
            write_bitplane_idx <= 0;
        end

        if (write_bitplane_idx != '1) begin
            screen_buffer[back_buffer][target_half_latch][write_bitplane_idx][screen_write_idx_latch >> 1]
              <= {
                1'b0,
                screen_write_rgb_latch[1][0][write_bitplane_idx],
                screen_write_rgb_latch[1][1][write_bitplane_idx],
                screen_write_rgb_latch[1][2][write_bitplane_idx],
                1'b0,
                screen_write_rgb_latch[0][0][write_bitplane_idx],
                screen_write_rgb_latch[0][1][write_bitplane_idx],
                screen_write_rgb_latch[0][2][write_bitplane_idx]
            };
            write_bitplane_idx <= write_bitplane_idx + 1;
            if (write_bitplane_idx == (COLOR_DEPTH - 1)) write_bitplane_idx <= '1;
        end

        if (reset_i) begin
            rgb_pixel_o <= 'hx;
            write_bitplane_idx <= '1;
        end
    end

`ifndef SYNTH
    initial begin
        for (int b = 0; b < 2; b++) begin
            for (int half = 0; half < 2; half++) begin
                for (int plane = 0; plane < COLOR_DEPTH; plane++) begin
                    for (logic[15:0] rowcol = 0; rowcol < (PANEL_WIDTH * PANEL_HEIGHT)/2/2; rowcol++) begin
                        logic [15:0] rowcol_0;
                        logic [15:0] rowcol_1;
                        rowcol_0 = rowcol * 2;
                        rowcol_1 = rowcol * 2 + 1;
                        screen_buffer[b][half][plane][rowcol] = {1'b0, rowcol_1[plane], rowcol_1[plane], rowcol_1[plane],
                                                                 1'b0, rowcol_0[plane], rowcol_0[plane], rowcol_0[plane]};
                    end
                end
            end
        end
    end
`endif
endmodule

/**
 * Accepts images and controls a hub75 led matrix.
 *
 * General procedure
 *   - Write out bitplane i for row m
 *   - Latch
 *   - Hold output enable high for appropriate amount of time
 *   - advance to row m + 1
 *   - after all rows serviced, advance to bitplane i + 1
 *
 * TODO:
 *   - accept reads to display memory (currently outputting constant)
 *   - Pipelined output / oe overlap
 */
module led_matrix_controller #(
    parameter WIDTH=32,
    parameter HEIGHT=32,
    parameter COLOR_DEPTH=8,
    parameter SCAN_RATIO=8,
    parameter OUTPUT_CLK_DIV=2
)  (
    input clk_i,
    input reset_i,

    // screen data write port
    // write address is in pixel indexes
    input [15:0] screen_write_x_i, screen_write_y_i,
    input [1:0] [2:0] [(COLOR_DEPTH-1):0] screen_write_rgb_i,
    input screen_write_valid_i,

    // output vsync strobe
    // Used to tell upstream hardware when it should start writing a new frame
    output logic vsync_o,

    // output data to led matrix
    output logic [$clog2(SCAN_RATIO)-1:0] led_addr_o,
    output logic [1:0] led_r_o,
    output logic [1:0] led_g_o,
    output logic [1:0] led_b_o,
    output logic led_clk_o,
    output logic led_latch_o,
    output logic led_oe_n_o
);
    ////////////////////////////////////////////////////////////////
    // parameter checking
    generate
        if (OUTPUT_CLK_DIV < 2) $error("parameter OUTPUT_CLK_DIV must be >= 2.");
        if (SCAN_RATIO != (1 << $clog2(SCAN_RATIO))) $error("parameter SCAN_RATIO must be a power of 2");
    endgenerate

    localparam PIXELS_PER_ROW = (WIDTH * (HEIGHT / (SCAN_RATIO * 2)));
    localparam LATCH_DWELL_TIME = 3;
    localparam OE_MIN_LENGTH = 64;

    localparam REPEAT_DISPLAY_COUNT = 2;

    ////////////////////////////////////////////////////////////////
    // output state tracking
    // Because the row that we're displaying and the row that we're shifting in can be different,
    // we keep 2 copies of each state variable: one that's pending (i.e. in the process of being
    // shifted out / about to be displayed) and one that's active (i.e. currently being displayed).

    // In order to regulate the refresh rate, we may display the same image multiple times in a
    // row. This counter keeps track of how many times we've displayed the same image.
    logic [7:0] image_repeat_count_pending, image_repeat_count_active;

    // Which bitplane are we presently displaying? Determines how long we hold oe low for.
    logic [3:0] bitplane_idx_pending, bitplane_idx_active;

    // Which row are we currently outputting?
    logic [7:0] row_idx_pending, row_idx_active;

    // Which "column" are we on in the current row?
    logic [15:0] col_idx;

    // What's the memory address that we're trying to read from?
    // This could be calculated from the above variables, but I feel that it's easier to just
    // calculate it directly in parallel.
    logic [23:0] mem_idx;

    // How many clock cycles have we been in the current state for?
    logic [31:0] state_clk_count;

    // Should we read from the memory on this cycle?
    logic do_mem_read;

    logic active_buffer_idx;

    ////////////////////////////////////////////////////////////////
    // memory
    logic [1:0] [2:0] rgb_pixel;
    screen_memory #(
        .PANEL_WIDTH(WIDTH), .PANEL_HEIGHT(HEIGHT),
        .COLOR_DEPTH(COLOR_DEPTH), .SCAN_RATIO(SCAN_RATIO)
    ) mem (
        .clk_i, .reset_i,
        .screen_write_x_i, .screen_write_y_i,
        .screen_write_rgb_i, .screen_write_valid_i,
        .active_buffer_i(active_buffer_idx), .read_bitplane_i(bitplane_idx_pending),
        .read_pointer_i(mem_idx),
        .do_read_i(do_mem_read), .rgb_pixel_o(rgb_pixel)
    );

    assign led_r_o = {rgb_pixel[1][0], rgb_pixel[0][0]};
    assign led_g_o = {rgb_pixel[1][1], rgb_pixel[0][1]};
    assign led_b_o = {rgb_pixel[1][2], rgb_pixel[0][2]};

    ////////////////////////////////////////////////////////////////
    // Drive output bus
    // how many internal clock cycles have passed between output clock cycles?
    logic [7:0] clk_divider_count, clk_divider_count_next;

    // how many clock cycles should we hold oe low for?
    logic [31:0] oe_dwell_count;

    // which state of the transmission are we in?
    typedef enum {
        STATE_DWELL,
        STATE_TRANSMIT,
        STATE_LATCH
    } state_t;
    state_t state, state_next;

    // On the subsequent cycle, should we output an edge on the LED clk?
    logic do_output_falling_edge, do_output_rising_edge;

    // which scan line are we on? counts up to SCAN_RATIO rows.
    logic [7:0] row_idx;
    logic [7:0] repeat_display_count;
    always_comb begin
        state_next = state;
        clk_divider_count_next = 0;

        case (state)
            STATE_DWELL: begin
                if (state_clk_count >= (oe_dwell_count + 10)) state_next = STATE_TRANSMIT;
            end

            STATE_TRANSMIT: begin
                if ((col_idx == (PIXELS_PER_ROW - 1)) &&
                    (clk_divider_count == (OUTPUT_CLK_DIV - 1))) state_next = STATE_LATCH;
                clk_divider_count_next = do_output_falling_edge ? 0 : clk_divider_count + 1;
            end

            STATE_LATCH: begin
                if (state_clk_count == LATCH_DWELL_TIME) state_next = STATE_DWELL;
            end
        endcase
    end

    always_comb begin
        do_output_falling_edge = ((state == STATE_TRANSMIT) &&
                                  (clk_divider_count == (OUTPUT_CLK_DIV - 1)));
        do_output_rising_edge = ((state == STATE_TRANSMIT) &&
                                 (clk_divider_count == ((OUTPUT_CLK_DIV / 2) - 1)));
    end

    always_ff @(posedge clk_i) begin
        // update clock. Only toggle it if we're in the transmit state.
        if (do_output_falling_edge) led_clk_o <= 0;
        if (do_output_rising_edge) led_clk_o <= 1;
        if (state != STATE_TRANSMIT) led_clk_o <= 0;

        // update state
        state <= state_next;

        // update counters
        if (state_next != state) state_clk_count <= 0;
        else state_clk_count <= state_clk_count + 1;

        clk_divider_count <= clk_divider_count_next;

        do_mem_read <= 0;
        if ((state == STATE_TRANSMIT) && (clk_divider_count_next == (OUTPUT_CLK_DIV - 1))) begin
            do_mem_read <= 1;
        end

        if (do_output_falling_edge) col_idx <= col_idx + 1;
        if (do_mem_read) begin
            mem_idx <= mem_idx + 1;

            // If we're in the last col of the last row, we reset the mem idx.
            if ((row_idx_pending == (SCAN_RATIO - 1)) && (col_idx == (PIXELS_PER_ROW - 2))) begin
                mem_idx <= 0;
            end
        end

        // vsync is 0 by default unless we are swapping a frame
        vsync_o <= 0;

        // on transition from transmit to latch, update state for pending and latched
        if ((state == STATE_TRANSMIT) && (state_next == STATE_LATCH)) begin
            // reset the column idx.
            col_idx <= 0;

            // the active row becomes the one that we were just shifting out.
            row_idx_active <= row_idx_pending;
            bitplane_idx_active <= bitplane_idx_pending;
            image_repeat_count_active <= image_repeat_count_pending;

            // set the oe dwell count
            oe_dwell_count <= OE_MIN_LENGTH << bitplane_idx_pending;

            // update the LED address pins here
            led_addr_o <= row_idx_pending;

            // increment row, bitplane, and image repeat counters.
            // for each image, we display it "image repeat" times.
            // for each repeat of the image, we display COLOR_DEPTH bitplanes.
            // for each bitplane, we have SCAN_RATIO rows.
            row_idx_pending <= row_idx_pending + 1;
            if (row_idx_pending == (SCAN_RATIO - 1)) begin
                row_idx_pending <= 0;

                bitplane_idx_pending <= bitplane_idx_pending + 1;
                if (bitplane_idx_pending == (COLOR_DEPTH - 1)) begin
                    bitplane_idx_pending <= 0;

                    image_repeat_count_pending <= image_repeat_count_pending + 1;
                    if (image_repeat_count_pending == (REPEAT_DISPLAY_COUNT-1)) begin
                        image_repeat_count_pending <= 0;

                        // swap backbuffer and strobe vsync
                        vsync_o <= 1;
                        active_buffer_idx <= active_buffer_idx + 1;
                    end
                end
            end
        end

        // drive oe_n_o
        // TODO: bitplanes
        if (state == STATE_DWELL) begin
            led_oe_n_o <= ~(state_clk_count < oe_dwell_count);
        end

        // drive latch high for a little
        // we have a dedicated state to make sure that it's high for long enough.
        led_latch_o <= (state == STATE_LATCH);

        // update address during the latch state
        if ((state != STATE_LATCH) && (state_next == STATE_LATCH)) row_idx <= row_idx + 1;

        if (reset_i) begin
            state <= STATE_DWELL;
            clk_divider_count <= 0;
            state_clk_count <= 0;
            row_idx <= '1;
            col_idx <= 0;
            mem_idx <= 1;
            led_oe_n_o <= 1;
            led_latch_o <= 0;
            oe_dwell_count <= 0;
            {image_repeat_count_pending, bitplane_idx_pending, row_idx_pending} <= 0;
            active_buffer_idx <= 0;
        end
    end // always_ff @ (posedge clk_i)

endmodule
