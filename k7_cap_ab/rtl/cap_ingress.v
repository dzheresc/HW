// Capture ingress (k7_cap), RX PCS clock domain.
//
// Takes the frame stream of the MAC receiver (or the test generator), decides at the
// start of each frame whether it fits in the on-chip buffers, and writes accepted
// frames as data words (data FIFO, at most snap_words per frame) plus one descriptor
// per frame (meta FIFO). A frame that does not fit is dropped whole and counted.
//
// Meta entry (128 bits):
//   [63:0]    timestamp (ts_clk ticks, 6.4 ns) at the first word of the frame
//   [79:64]   captured length (bytes in the data FIFO, <= snap_words*8)
//   [95:80]   wire length (bytes seen by the MAC; includes the FCS when it is kept)
//   [103:96]  flags: [0] bad frame (FCS / framing error) [1] truncated to snaplen
//                    [2] FCS included [3] aborted (MAC reset mid-frame)
//   [119:104] frames dropped since the previous delivered record (saturates at 65535)
//   [120]     discard: data words are in the FIFO but the record is not delivered
// The number of data words of an entry is ceil(captured length / 8).
`default_nettype none
module cap_ingress #(
  parameter integer DAW = 15,      // data FIFO address width (words)
  parameter integer MAW = 12       // meta FIFO address width
) (
  input  wire         clk,
  input  wire         rst,         // capture reset (FIFO write side)
  input  wire         mac_rst,     // MAC / PCS reset: closes a frame in progress

  input  wire [63:0]  s_tdata,
  input  wire [7:0]   s_tkeep,
  input  wire         s_tvalid,
  input  wire         s_tlast,
  input  wire         s_tuser,     // bad frame

  input  wire [63:0]  ts,
  input  wire         cfg_enable,
  input  wire [11:0]  cfg_snap_words,  // 8..2048
  input  wire         cfg_keep_bad,
  input  wire         cfg_keep_fcs,

  output reg          d_we = 1'b0,
  output reg  [63:0]  d_data,
  input  wire [DAW:0] d_free,
  output reg          m_we = 1'b0,
  output reg  [127:0] m_data,
  input  wire [MAW:0] m_free,

  // counters (free running from rst)
  output reg  [63:0]  c_rx_frames = 0,   // all frames the MAC delivered
  output reg  [63:0]  c_rx_bytes = 0,
  output reg  [63:0]  c_cap_frames = 0,  // records delivered
  output reg  [63:0]  c_drop_frames = 0, // dropped for lack of buffer space (while enabled)
  output reg  [63:0]  c_bad_frames = 0,  // FCS / framing errors
  output reg  [DAW:0] c_dfifo_max_used = 0
);
  function [3:0] nbytes(input [7:0] k);
    case (k)
      8'h01: nbytes = 4'd1; 8'h03: nbytes = 4'd2; 8'h07: nbytes = 4'd3; 8'h0F: nbytes = 4'd4;
      8'h1F: nbytes = 4'd5; 8'h3F: nbytes = 4'd6; 8'h7F: nbytes = 4'd7; default: nbytes = 4'd8;
    endcase
  endfunction

  reg         in_frame = 1'b0;
  reg         cap = 1'b0;          // capturing the current frame
  reg  [11:0] words = 0;           // data words written for the current frame
  reg  [15:0] bytes = 0;           // bytes seen so far (saturating at 65535)
  reg  [63:0] ts_sof = 0;
  reg  [15:0] drops_since = 0;
  reg  [11:0] snap_q = 12'd1200;

  wire        sof = s_tvalid && !in_frame;
  // Room for a whole frame (at the snap length) plus a little slack, and one descriptor.
  wire        room = (d_free >= snap_q + 12'd4) && (m_free >= 2);
  wire        acc  = sof ? (cfg_enable && room) : cap;
  wire [11:0] wcnt = sof ? 12'd0 : words;
  wire [15:0] bsum = (sof ? 16'd0 : bytes) + nbytes(s_tkeep);
  wire [15:0] fbytes = (!sof && bytes > 16'd65527) ? 16'hFFFF : bsum;
  wire        store = acc && s_tvalid && (wcnt < snap_q);
  wire [11:0] wnext = wcnt + store;
  wire [15:0] snap_bytes = {1'b0, snap_q, 3'b000};

  always @(posedge clk) begin
    d_we <= 1'b0;
    m_we <= 1'b0;
    if (rst) begin
      in_frame <= 1'b0;  cap <= 1'b0;  words <= 0;  bytes <= 0;  drops_since <= 0;
      c_rx_frames <= 0;  c_rx_bytes <= 0;  c_cap_frames <= 0;  c_drop_frames <= 0;
      c_bad_frames <= 0;  c_dfifo_max_used <= 0;
      snap_q <= cfg_snap_words;
    end else begin
      if (!in_frame && !s_tvalid) snap_q <= cfg_snap_words;   // only changes between frames
      if ((1 << DAW) - d_free > c_dfifo_max_used) c_dfifo_max_used <= (1 << DAW) - d_free;

      if (mac_rst) begin
        // frame cut short by a MAC reset: hand back the words already written
        if (in_frame && cap) begin
          m_we   <= 1'b1;
          m_data <= {7'd0, 1'b1, drops_since, 8'h08, bytes, {1'b0, words, 3'b000}, ts_sof};
        end
        in_frame <= 1'b0;  cap <= 1'b0;
      end else if (s_tvalid) begin
        if (sof) begin
          ts_sof <= ts;
          cap    <= acc;
        end
        if (store) begin
          d_we   <= 1'b1;
          d_data <= s_tdata;
        end
        words <= wnext;
        bytes <= fbytes;
        in_frame <= !s_tlast;

        if (s_tlast) begin
          c_rx_frames <= c_rx_frames + 1'b1;
          c_rx_bytes  <= c_rx_bytes + fbytes;
          if (s_tuser) c_bad_frames <= c_bad_frames + 1'b1;
          if (acc) begin : deliver
            reg        trunc, discard;
            reg [15:0] clen;
            trunc   = fbytes > snap_bytes;
            clen    = trunc ? snap_bytes : fbytes;
            discard = s_tuser && !cfg_keep_bad;
            m_we   <= 1'b1;
            m_data <= {7'd0, discard, drops_since,
                       4'd0, 1'b0, cfg_keep_fcs, trunc, s_tuser,
                       fbytes, clen, sof ? ts : ts_sof};
            if (!discard) begin
              c_cap_frames <= c_cap_frames + 1'b1;
              drops_since  <= 0;
            end
          end else if (cfg_enable) begin
            c_drop_frames <= c_drop_frames + 1'b1;
            if (drops_since != 16'hFFFF) drops_since <= drops_since + 1'b1;
          end
        end
      end
    end
  end
endmodule
`default_nettype wire
