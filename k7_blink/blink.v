// 6-bit binary counter on the LEDs, clocked from the 100 MHz oscillator.
// The counter advances every 125 ms, so LED0 (LSB) toggles every 125 ms and
// completes 4 full on/off cycles per second; LED1 2/s, LED2 1/s, and so on.
module blink #(
    parameter integer CLK_HZ   = 100_000_000,
    parameter integer TICK_DIV = CLK_HZ / 8      // 12_500_000 cycles = 125 ms
) (
    input  wire       clk,
    output wire [5:0] led
);
    reg [23:0] prescaler = 24'd0;
    reg [5:0]  count     = 6'd0;

    always @(posedge clk) begin
        if (prescaler == TICK_DIV - 1) begin
            prescaler <= 24'd0;
            count     <= count + 6'd1;
        end else begin
            prescaler <= prescaler + 24'd1;
        end
    end

    assign led = count;
endmodule
