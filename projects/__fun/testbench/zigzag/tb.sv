`timescale 1ns/10ps

// print x y indices

module tb;
    localparam PANEL_WIDTH = 16;
    localparam PANEL_HEIGHT = 16;
    localparam SCAN_RATIO = 8;

    initial begin
        $write("      ");
        for (int x = 0; x < PANEL_WIDTH; x++) begin
            $write("%4d ", x);
        end
        $write("\n\n");

        for (int y = 0; y < PANEL_HEIGHT; y++) begin
            $write("%2d    ", y);
            for (int x = 0; x < PANEL_WIDTH; x++) begin
                $write("%4d ", xy_loc_to_base_memory_address(
                    x, y,
                    $clog2(PANEL_WIDTH), $clog2(PANEL_HEIGHT),
                    $clog2(SCAN_RATIO)
                ));
            end
            $write("\n");
        end
        $write("\n\n");
        $finish;
    end
endmodule
