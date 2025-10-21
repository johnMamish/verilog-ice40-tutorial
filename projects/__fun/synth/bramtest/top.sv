module bram (
    input clk,
    input [13:0] addr,
    input [15:0] data,
    input read,
    input thing,
    input write,

    output logic [1:0] [2:0] data_o
);

    localparam BITPLANE_LENGTH_BYTES = (64 * 64)/(2 * 2);
    localparam BUFFER_SIZE_BYTES = 8 * BITPLANE_LENGTH_BYTES;

    (* ram_style = "huge" *) reg [7:0] mem [BUFFER_SIZE_BYTES-1:0];

    logic [13:0] addr_input;

    always_comb addr_input = ~addr;

    logic [7:0] count;

    always_ff @(posedge clk) begin
        //addr_input <= addr;
        count <= count + 1;

        if (read && (count == '1)) begin
            data_o[0] <= mem[addr_input];
        end else if (write) begin
            mem[addr_input] <= data;
        end
    end

endmodule
