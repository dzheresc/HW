//////////////////////////////////////////////////////////////////////////////////
// Module Name: clk_divider_4x
// Description: Divides input clock by 4 (100MHz -> 25MHz)
//////////////////////////////////////////////////////////////////////////////////

module clk_divider_4x(
    input wire clk_in,
    output reg clk_out,
    input wire reset
);

    reg [1:0] counter;

    always @(posedge clk_in or posedge reset) begin
        if (reset) begin
            counter <= 2'b00;
            clk_out <= 1'b0;
        end else begin
            counter <= counter + 1'b1;
            if (counter == 2'b01) begin
                clk_out <= ~clk_out;
                counter <= 2'b00;
            end
        end
    end

endmodule

