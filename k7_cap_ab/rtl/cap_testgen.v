// Test frame generator (k7_cap_ab, one per port), RX PCS clock domain. Never reaches the
// wire: when enabled its frames replace the MAC receiver output at the capture input, to
// load the DMA path at (or above) 10G line rate.
//
// Frame: dst ff:ff:ff:ff:ff:ff, src 02:4b:37:00:PP:6e (PP = PORT), EtherType 0x88b5, 2 zero
// bytes, then a 64-bit little-endian sequence number (bytes 16..23, starts at 0
// after a capture reset), then words {seq[31:0], 16'd0, word index} up to len bytes.
// One frame every len/8 + gap cycles (156.25 MHz): len 60, gap 3 -> 11 cycles
// = 14.2 Mframes/s, about line rate for minimum-size frames.
`default_nettype none
module cap_testgen #(
  parameter [6:0] PORT = 7'd0
) (
  input  wire        clk,
  input  wire        rst,
  input  wire        enable,
  input  wire [15:0] cfg_len,    // bytes, 17..16383
  input  wire [15:0] cfg_gap,    // idle cycles after each frame, >= 1

  output reg  [63:0] m_tdata = 0,
  output reg  [7:0]  m_tkeep = 0,
  output reg         m_tvalid = 1'b0,
  output reg         m_tlast = 1'b0,
  output reg  [63:0] seq = 0      // frames generated since the capture reset
);
  reg  [15:0] len_q = 16'd60, gap_q = 16'd3;
  reg  [12:0] widx = 0;
  reg  [15:0] gcnt = 0;
  wire [12:0] nwords = (len_q + 16'd7) >> 3;
  wire [2:0]  tail = len_q[2:0];

  always @(posedge clk) begin
    m_tvalid <= 1'b0;
    m_tlast  <= 1'b0;
    if (rst) begin
      widx <= 0;  gcnt <= 0;  seq <= 0;
    end else if (gcnt != 0) begin
      gcnt <= gcnt - 1'b1;
    end else if (widx == 0 && !enable) begin
      // stopped (only between frames): pick up the configuration
      len_q <= (cfg_len < 16'd17) ? 16'd17 : (cfg_len > 16'd16383 ? 16'd16383 : cfg_len);
      gap_q <= (cfg_gap == 16'd0) ? 16'd1 : cfg_gap;
    end else begin
      m_tvalid <= 1'b1;
      case (widx)
        13'd0:   m_tdata <= 64'h4b02_ffff_ffff_ffff;
        13'd1:   m_tdata <= {32'h0000_b588, 8'h6e, 1'b0, PORT, 16'h0037};
        13'd2:   m_tdata <= seq;
        default: m_tdata <= {seq[31:0], 16'd0, 3'd0, widx};
      endcase
      if (widx == nwords - 1'b1) begin
        m_tlast <= 1'b1;
        m_tkeep <= (tail == 3'd0) ? 8'hFF : (8'hFF >> (4'd8 - tail));
        widx <= 0;
        gcnt <= gap_q;
        seq  <= seq + 1'b1;
      end else begin
        m_tkeep <= 8'hFF;
        widx <= widx + 1'b1;
      end
    end
  end
endmodule
`default_nettype wire
