// Clock Divider Module
// Divides input clock by 4 to generate 25 MHz from 100 MHz
// Uses a 2-bit counter for divide-by-4 operation

module clk_divider (
    input wire clk_in,      // Input clock (100 MHz)
    input wire rst,         // Reset (active high, optional)
    output reg clk_out      // Output clock (25 MHz)
);

    // 2-bit counter for divide-by-4
    reg [1:0] counter;

    always @(posedge clk_in) begin
        if (rst) begin
            counter <= 2'b0;
            clk_out <= 1'b0;
        end else begin
            counter <= counter + 1'b1;
            // Use MSB of counter as output (toggles every 2 cycles = divide by 4)
            // Counter: 00, 01, 10, 11 -> counter[1]: 0, 0, 1, 1
            clk_out <= counter[1];
        end
    end

endmodule

