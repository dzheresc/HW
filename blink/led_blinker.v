//////////////////////////////////////////////////////////////////////////////////
// Module: led_blinker.v
// Description: Simple LED blinker that flashes at 1Hz
//              Divides input clock to generate 1Hz output
//////////////////////////////////////////////////////////////////////////////////

module led_blinker (
    input wire clk,        // Input clock (typically 100MHz)
    input wire rst,        // Reset signal (active high)
    output reg led         // LED output (1Hz blinking)
);

    // Calculate counter width for 1Hz from 100MHz clock
    // 100MHz / 1Hz = 100,000,000
    // Need to count to 50,000,000 for 0.5s (half period)
    // log2(50,000,000) ≈ 26 bits
    parameter CLK_FREQ = 100_000_000;  // Input clock frequency in Hz
    parameter TARGET_FREQ = 1;          // Target frequency in Hz
    parameter COUNTER_MAX = (CLK_FREQ / (2 * TARGET_FREQ)) - 1;
    parameter COUNTER_WIDTH = $clog2(COUNTER_MAX);
    
    reg [COUNTER_WIDTH-1:0] counter;
    
    always @(posedge clk) begin
        if (rst) begin
            counter <= 0;
            led <= 0;
        end else begin
            if (counter >= COUNTER_MAX) begin
                counter <= 0;
                led <= ~led;  // Toggle LED
            end else begin
                counter <= counter + 1;
            end
        end
    end

endmodule

