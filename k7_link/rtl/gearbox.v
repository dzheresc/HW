// 66b <-> 64b gearboxes for a GTX in raw 64-bit mode at 10.3125 Gb/s (161.13 MHz).
// Serial order is LSB first: block bit 0 (sync header bit 0) goes on the line first.
// 32 blocks of 66 bits fit in 33 words of 64 bits, so the 66-bit side stalls
// one cycle in 33. The PCS runs on a BUFGCE-gated copy of the word clock, enabled
// by `ce`/`valid`, which makes it see a clean 156.25 MHz (average) block stream.
`default_nettype none

// TX: block in (from PCS on the gated clock), word out (to GTX TXDATA).
module gearbox_tx (
    input  wire        clk,       // TXUSRCLK2, 161.13 MHz
    input  wire        rst,
    input  wire [65:0] blk,       // {data[63:0], hdr[1:0]}, held by the PCS between gated edges
    output reg         ce = 1'b1, // BUFGCE enable for the PCS clock: high = the PCS advances at the next edge
    output reg  [63:0] word = 64'd0
);
    reg  [5:0]   seq = 6'd0;      // 0..32; seq 32 is the stall cycle (no block taken)
    reg  [65:0]  lo  = 66'd0;     // leftover bits, 2*seq of them
    wire         take = (seq != 6'd32);
    wire [129:0] comb = take ? (({64'd0, blk} << {seq, 1'b0}) | {64'd0, lo}) : {64'd0, lo};

    always @(posedge clk) begin
        if (rst) begin
            seq  <= 6'd0;
            lo   <= 66'd0;
            ce   <= 1'b1;
            word <= 64'd0;
        end else begin
            word <= comb[63:0];
            lo   <= comb[129:64];
            seq  <= (seq == 6'd32) ? 6'd0 : seq + 6'd1;
            ce   <= (seq != 6'd31);   // the edge that ends seq 32 must not advance the PCS
        end
    end
endmodule

// RX: word in (from GTX RXDATA), block + valid out. `slip` shifts the alignment by one bit.
module gearbox_rx (
    input  wire        clk,       // RXUSRCLK2, 161.13 MHz (recovered)
    input  wire        rst,
    input  wire [63:0] word,
    input  wire        slip,      // one-cycle pulse
    output reg  [65:0] blk = 66'd0,
    output reg         valid = 1'b0
);
    reg [63:0]  w0 = 0, w1 = 0, w2 = 0;   // w2 oldest
    reg [7:0]   p  = 8'd0;                // offset of the next block in {w0,w1,w2}, 0..129
    wire [191:0] win = {w0, w1, w2};
    wire        emit = (p <= 8'd126);

    // two-stage extraction: coarse byte shift (16 positions), then fine bit shift (8 positions)
    reg  [72:0] coarse = 0;
    reg  [2:0]  fine   = 0;
    reg         v1     = 1'b0;
    wire [191:0] win_sh = win >> {p[6:3], 3'b000};

    always @(posedge clk) begin
        w0 <= word; w1 <= w0; w2 <= w1;
        coarse <= win_sh[72:0];
        fine   <= p[2:0];
        blk    <= coarse >> fine;
        if (rst) begin
            p     <= 8'd0;
            v1    <= 1'b0;
            valid <= 1'b0;
        end else begin
            v1    <= emit;
            valid <= v1;
            p <= (emit ? p + 8'd2 : p - 8'd64) + (slip ? 8'd1 : 8'd0);
        end
    end
endmodule

`default_nettype wire
