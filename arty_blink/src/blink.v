`timescale 1ns / 1ps
`default_nettype none
//------------------------------------------------------------------------------
// blink.v - LED blinker for Digilent Arty A7-35T (xc7a35ticsg324-1L)
//
//   100 MHz board clock -> tick every 1/(2*BLINK_HZ) s -> 4-bit counter on
//   LD4..LD7.  led[0] blinks at BLINK_HZ, led[1] at BLINK_HZ/2, and so on.
//   rst_n is the board RESET button (active low); it is synchronised on chip.
//------------------------------------------------------------------------------
module blink #(
    parameter integer CLK_HZ   = 100_000_000,  // input clock frequency [Hz]
    parameter integer BLINK_HZ = 1             // blink rate of led[0]  [Hz]
) (
    input  wire       clk,    // 100 MHz oscillator
    input  wire       rst_n,  // active-low, asynchronous push button
    output wire [3:0] led     // LD4..LD7
);
    // led[0] toggles every HALF clocks -> period = 2*HALF clocks = CLK_HZ/BLINK_HZ
    localparam integer HALF  = CLK_HZ / (2 * BLINK_HZ);
    localparam integer CNT_W = (HALF > 1) ? $clog2(HALF) : 1;

    // --- reset synchroniser: asynchronous assert, synchronous release --------
    reg [1:0] rst_sync = 2'b00;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) rst_sync <= 2'b00;
        else        rst_sync <= {rst_sync[0], 1'b1};
    wire rst = ~rst_sync[1];

    // --- tick generator --------------------------------------------------------
    reg [CNT_W-1:0] cnt  = {CNT_W{1'b0}};
    reg             tick = 1'b0;
    always @(posedge clk)
        if (rst) begin
            cnt  <= {CNT_W{1'b0}};
            tick <= 1'b0;
        end else if (cnt == HALF - 1) begin
            cnt  <= {CNT_W{1'b0}};
            tick <= 1'b1;
        end else begin
            cnt  <= cnt + 1'b1;
            tick <= 1'b0;
        end

    // --- LED counter -----------------------------------------------------------
    reg [3:0] led_r = 4'b0000;
    always @(posedge clk)
        if (rst)       led_r <= 4'b0000;
        else if (tick) led_r <= led_r + 1'b1;

    assign led = led_r;
endmodule
`default_nettype wire
